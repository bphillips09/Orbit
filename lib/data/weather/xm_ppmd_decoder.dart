import 'dart:collection';
import 'dart:typed_data';

/// Decompresses odd-mode payloads (0x49 preamble)
class XmPpmdDecoder {
  static Uint8List? decode(
    Uint8List payload, {
    required int expectedOutputLength,
    Duration timeout = const Duration(seconds: 2),
  }) =>
      xmPpmdDecodeImpl(
        payload,
        expectedOutputLength,
        timeout: timeout,
      );
}

const int _rangeBottom = 1 << 15;
const int _rangeTop = 1 << 24;
const int _maxFreq = 124;
const int _intBits = 7;
const int _periodBits = 7;
const int _binScale = 1 << (_intBits + _periodBits);
const int _unitSize = 12;
const int _maxUint16 = 0xFFFF;
const int _freeMark = -1;
const int _n0 = 1;
const int _n1 = 4;
const int _n2 = 4;
const int _n3 = 4;
const int _n4 = (128 + 3 - _n1 - 2 * _n2 - 3 * _n3) ~/ 4;
const int _nIndexes = _n0 + _n1 + _n2 + _n3 + _n4;

const List<int> _expEscape = <int>[
  25,
  14,
  9,
  7,
  5,
  5,
  4,
  4,
  4,
  3,
  3,
  3,
  2,
  2,
  2,
  2,
];
const List<int> _initBinEsc = <int>[
  0x3CDD,
  0x1F3F,
  0x59BF,
  0x48F3,
  0x64A1,
  0x5ABC,
  0x6632,
  0x6051,
];

int _u32(int x) => x & 0xFFFFFFFF;

final Uint8List _ns2Index = Uint8List(256);
final Uint8List _ns2BSIndex = Uint8List(256);
final Uint8List _units2Index = Uint8List(128 + 1);
final Int32List _index2Units = Int32List(_nIndexes);
final Uint8List _binSummFreqIndex = Uint8List(256);
final Int32List _binSummRowDivisors = Int32List(25);
final Int32List _seeRowInitialSummaries = Int32List(24);
bool _ppmTablesInited = false;

void _initPpmTables() {
  if (_ppmTablesInited) return;
  // Build tables in a small startup routine
  final List<int> seq = List<int>.filled(0x104, 0);
  for (int i = 0; i < 5; i++) {
    seq[i] = i;
  }
  int eax = 5;
  int esi = 1;
  int edx = eax;
  int ecx = esi;
  while (eax < seq.length) {
    ecx--;
    seq[eax] = edx & 0xFF;
    if (ecx == 0) {
      esi++;
      edx++;
      ecx = esi;
    }
    eax++;
  }

  _ns2BSIndex[0] = 0;
  _ns2BSIndex[1] = 2;
  for (int i = 2; i < 11; i++) {
    _ns2BSIndex[i] = 4;
  }
  for (int i = 11; i < 256; i++) {
    _ns2BSIndex[i] = 6;
  }

  for (int i = 0; i < 256; i++) {
    _ns2Index[i] = i == 0 ? 0 : ((seq[i + 2] - 3) & 0xFF);
    _binSummFreqIndex[i] = seq[i] & 0xFF;
  }

  int value = 1;
  for (int i = 0; i < 4; i++) {
    _index2Units[i] = value;
    value++;
  }
  for (int i = 4; i < 8; i++) {
    _index2Units[i] = value;
    value += 2;
  }
  value++;
  for (int i = 8; i < 12; i++) {
    _index2Units[i] = value;
    value += 3;
  }
  value++;
  for (int i = 12; i < _nIndexes; i++) {
    _index2Units[i] = value;
    value += 4;
  }

  int classIndex = 0;
  for (int units = 1; units < _units2Index.length; units++) {
    while (classIndex + 1 < _index2Units.length &&
        _index2Units[classIndex] < units) {
      classIndex++;
    }
    _units2Index[units] = classIndex & 0xFF;
  }

  int rowClass = 0;
  for (int target = 3; target < 27; target++) {
    int b = seq[3 + rowClass];
    while (b == target) {
      b = seq[4 + rowClass];
      rowClass++;
    }
    _seeRowInitialSummaries[target - 3] = 0x28 + (rowClass << 4);
  }

  int freqClass = 0;
  for (int target = 0; target < _binSummRowDivisors.length; target++) {
    int b = seq[freqClass];
    while (b == target) {
      b = seq[freqClass + 1];
      freqClass++;
    }
    _binSummRowDivisors[target] = freqClass + 1;
  }
  _ppmTablesInited = true;
}

Uint8List? xmPpmdDecodeImpl(
  Uint8List payload,
  int expectedOutputLength, {
  Duration timeout = const Duration(seconds: 2),
}) {
  if (payload.length < 3) return null;
  if ((payload[0] & 0xFF) != 0x49) return null;
  final int restoreMethod = (payload[2] >> 4) & 0x0F;
  if (restoreMethod > 2) return null;
  final int maxOrder = (payload[2] & 0x0F) + 1;
  if (maxOrder < 1 || maxOrder > 16) return null;
  final int mem = (payload[1] & 0xFF) + 1;
  final int memoryBytes = mem == 1 ? 0x60000 : (mem << 20);
  if (expectedOutputLength <= 0) return null;

  _initPpmTables();
  final _ByteReader br = _ByteReader(payload, 3);
  final _Model m = _Model();
  final Stopwatch stopwatch = Stopwatch()..start();
  m.setDeadline(stopwatch, timeout);
  if (!m.init(
    br,
    reset: true,
    maxOrder: maxOrder,
    memoryBytes: memoryBytes,
    restoreMethod: restoreMethod,
  )) {
    return null;
  }
  final Uint8List out = Uint8List(expectedOutputLength);
  for (int i = 0; i < expectedOutputLength; i++) {
    if ((i & 0x3FF) == 0 && m.isTimedOut()) {
      return null;
    }
    final int? b = m.readByte();
    if (b == null || b > 255) return null;
    out[i] = b;
  }
  return out;
}

class _ByteReader {
  _ByteReader(this.data, this.start);
  final Uint8List data;
  final int start;
  int pos = 0;
  int? readByte() {
    final int i = start + pos;
    if (i >= data.length) return null;
    pos++;
    return data[i] & 0xFF;
  }
}

class _RangeCoder {
  _ByteReader? br;
  int code = 0;
  int low = 0;
  int rnge = 0;
  bool Function()? shouldAbort;
  int _normalizeTicks = 0;

  bool init(_ByteReader b) {
    br = b;
    low = 0;
    rnge = 0xFFFFFFFF;
    for (int i = 0; i < 4; i++) {
      final int? c = br!.readByte();
      if (c == null) return false;
      code = _u32((code << 8) | c);
    }
    return true;
  }

  int currentCount(int scale) {
    rnge ~/= scale;
    return (code - low) ~/ rnge;
  }

  bool normalize() {
    while (true) {
      if (((_normalizeTicks++) & 0x3FF) == 0 &&
          (shouldAbort?.call() ?? false)) {
        return false;
      }
      if (_u32(low ^ (low + rnge)) >= _rangeTop) {
        if (rnge >= _rangeBottom) {
          return true;
        }
        rnge = _u32(-low) & (_rangeBottom - 1);
      }
      final int? c = br!.readByte();
      if (c == null) return false;
      code = _u32((code << 8) | c);
      rnge = _u32(rnge << 8);
      low = _u32(low << 8);
    }
  }

  bool decode(int lowCount, int highCount) {
    low = _u32(low + rnge * lowCount);
    rnge = _u32(rnge * (highCount - lowCount));
    return normalize();
  }
}

class _See2Context {
  _See2Context({
    required this.summ,
    required this.shift,
    required this.count,
  });
  int summ;
  int shift;
  int count;

  int mean() {
    final int n = summ >> shift;
    if (n == 0) return 1;
    summ -= n;
    return n;
  }

  void update() {
    if (shift >= _periodBits) return;
    count--;
    if (count == 0) {
      summ += summ;
      count = 3 << shift;
      shift++;
    }
  }
}

class _State {
  _State({this.sym = 0, this.freq = 0, this.succ = 0});
  int sym;
  int freq;
  int succ;

  int uint16() => (sym & 0xFF) | ((freq & 0xFF) << 8);
  void setUint16(int n) {
    sym = n & 0xFF;
    freq = (n >> 8) & 0xFF;
  }
}

int _succContext(int i) => i <= 0 ? 0 : i;

class _StateSlice extends ListBase<_State> {
  _StateSlice(this._base, this._start, this._length);

  final List<_State> _base;
  final int _start;
  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) {
    throw UnsupportedError('Fixed-length view');
  }

  @override
  _State operator [](int index) => _base[_start + index];

  @override
  void operator []=(int index, _State value) {
    _base[_start + index] = value;
  }
}

class _SubAllocator {
  int glueCount = 0;
  int heap1MaxBytes = 0;
  int heap1Lo = 0;
  int heap1Hi = 0;
  int heap2Lo = 0;
  int heap2Hi = 0;
  final Int32List freeList = Int32List(_nIndexes);
  List<_State> states = <_State>[];

  void init(int totalBytes) {
    final int bytes = totalBytes;
    final int heap2Units = bytes ~/ 8 ~/ _unitSize * 7;
    heap1MaxBytes = bytes - heap2Units * _unitSize;
    final int heap1Units = heap1MaxBytes ~/ _unitSize + 1;
    final int n = (1 + heap1Units + heap2Units) * 2;
    states = List<_State>.generate(n, (_) => _State());
  }

  void restart() {
    heap1Lo = _unitSize + (_unitSize - heap1MaxBytes % _unitSize);
    heap1Hi = _unitSize + (heap1MaxBytes ~/ _unitSize + 1) * _unitSize;
    heap2Lo = heap1Hi ~/ _unitSize * 2;
    heap2Hi = states.length;
    glueCount = 0;
    for (int i = 0; i < _nIndexes; i++) {
      freeList[i] = 0;
    }
  }

  int pushByte(int c) {
    final int si = heap1Lo ~/ 6;
    final int oi = heap1Lo % 6;
    if (oi == 0) {
      states[si].sym = c;
    } else if (oi == 1) {
      states[si].freq = c;
    } else {
      final int n = (oi - 2) * 8;
      final int mask = ~(0xFF << n);
      int succ = states[si].succ & mask;
      succ |= (c & 0xFF) << n;
      states[si].succ = succ;
    }
    heap1Lo++;
    if (heap1Lo >= heap1Hi) {
      return 0;
    }
    return -heap1Lo;
  }

  void popByte() {
    heap1Lo--;
  }

  int succByte(int i) {
    int ii = -i;
    final int si = ii ~/ 6;
    final int oi = ii % 6;
    switch (oi) {
      case 0:
        return states[si].sym & 0xFF;
      case 1:
        return states[si].freq & 0xFF;
      default:
        final int n = (oi - 2) * 8;
        final int succ = _u32(states[si].succ);
        return (succ >> n) & 0xFF;
    }
  }

  int nextByteAddr(int n) => n - 1;

  int removeFreeBlock(int i) {
    int n = freeList[i];
    if (n != 0) {
      freeList[i] = states[n].succ;
      states[n] = _State();
    }
    return n;
  }

  void addFreeBlock(int n, int i) {
    states[n].succ = freeList[i];
    freeList[i] = n;
  }

  void freeUnits(int n, int u) {
    int i = _units2Index[u];
    if (u != _index2Units[i]) {
      i--;
      addFreeBlock(n, i);
      u -= _index2Units[i];
      n += _index2Units[i] << 1;
      i = _units2Index[u];
    }
    addFreeBlock(n, i);
  }

  void glueFreeBlocks() {
    int freeIndex = 0;
    for (int i = 0; i < _nIndexes; i++) {
      int n = freeList[i];
      final _State s = _State(succ: _freeMark);
      s.setUint16(_index2Units[i] & 0xFFFF);
      while (n != 0) {
        states[n + 1].succ = freeIndex;
        freeIndex = n;
        final int next = states[n].succ;
        states[n] = _State(sym: s.sym, freq: s.freq, succ: s.succ);
        n = next;
      }
      freeList[i] = 0;
    }
    for (int i = freeIndex; i != 0; i = states[i + 1].succ) {
      if (states[i].succ != _freeMark) continue;
      int u = states[i].uint16();
      int idx = i + (u << 1);
      while (idx < states.length && states[idx].succ == _freeMark) {
        u += states[idx].uint16();
        if (u > _maxUint16) break;
        states[idx].succ = 0;
        states[i].setUint16(u);
        idx = i + (u << 1);
      }
    }
    for (int n = freeIndex; n != 0; n = states[n + 1].succ) {
      if (states[n].succ != _freeMark) continue;
      states[n].succ = 0;
      int u = states[n].uint16();
      int m = n;
      while (u > 128) {
        addFreeBlock(m, _nIndexes - 1);
        u -= 128;
        m += 256;
      }
      freeUnits(m, u);
    }
  }

  int allocUnitsRare(int index) {
    if (glueCount == 0) {
      glueCount = 255;
      glueFreeBlocks();
      final int n = removeFreeBlock(index);
      if (n > 0) return n;
    }
    for (int i = index + 1; i < _nIndexes; i++) {
      final int n = removeFreeBlock(i);
      if (n > 0) {
        final int u = _index2Units[i] - _index2Units[index];
        freeUnits(n + (_index2Units[index] << 1), u);
        return n;
      }
    }
    glueCount--;
    int n = heap1Hi - _index2Units[index] * _unitSize;
    if (n > heap1Lo) {
      heap1Hi = n;
      return heap1Hi ~/ _unitSize * 2;
    }
    return 0;
  }

  int allocUnits(int i) {
    final int n0 = removeFreeBlock(i);
    if (n0 > 0) return n0;
    int n = _index2Units[i] << 1;
    if (heap2Lo + n <= heap2Hi) {
      final int lo = heap2Lo;
      heap2Lo += n;
      return lo;
    }
    return allocUnitsRare(i);
  }

  int newContext(_State s, int suffix, {int flags = 0}) {
    int n;
    if (heap2Lo < heap2Hi) {
      heap2Hi -= 2;
      n = heap2Hi;
    } else {
      n = removeFreeBlock(1);
      if (n == 0) {
        n = allocUnitsRare(1);
        if (n == 0) return 0;
      }
    }
    states[n] = _State(freq: flags & 0xFF, succ: suffix);
    states[n + 1] = _State(sym: s.sym, freq: s.freq, succ: s.succ);
    return n;
  }

  int newContextSize(int ns) {
    int c = newContext(_State(), 0);
    contextSetNumStates(c, ns);
    final int i = _units2Index[(ns + 1) >> 1];
    final int n = allocUnits(i);
    contextSetStatesIndex(c, n);
    return c;
  }

  int contextNumStates(int c) => (states[c].sym & 0xFF) + 1;
  void contextSetNumStates(int c, int n) {
    states[c].sym = n - 1;
  }

  int contextFlags(int c) => states[c].freq & 0xFF;
  void contextSetFlags(int c, int flags) {
    states[c].freq = flags & 0xFF;
  }

  int contextSummFreq(int c) => states[c + 1].uint16();
  void contextSetSummFreq(int c, int n) => states[c + 1].setUint16(n);
  void contextIncSummFreq(int c, int n) {
    states[c + 1].setUint16(states[c + 1].uint16() + n);
  }

  int contextSuffix(int c) => _succContext(states[c].succ);

  int contextStatesIndex(int c) => states[c + 1].succ;
  void contextSetStatesIndex(int c, int n) {
    states[c + 1].succ = n;
  }

  List<_State> contextStates(int c) {
    final int ns = (states[c].sym & 0xFF) + 1;
    if (ns != 1) {
      final int i = states[c + 1].succ;
      return _StateSlice(states, i, ns);
    }
    return _StateSlice(states, c + 1, 1);
  }

  List<_State> shrinkStates(int c, List<_State> st, int size) {
    final int i1 = _units2Index[(st.length + 1) >> 1];
    final int i2 = _units2Index[(size + 1) >> 1];
    if (size == 1) {
      final int n = contextStatesIndex(c);
      states[c + 1] =
          _State(sym: st[0].sym, freq: st[0].freq, succ: st[0].succ);
      addFreeBlock(n, i1);
    } else if (i1 != i2) {
      final int n = removeFreeBlock(i2);
      if (n > 0) {
        for (int k = 0; k < size; k++) {
          states[n + k] =
              _State(sym: st[k].sym, freq: st[k].freq, succ: st[k].succ);
        }
        addFreeBlock(contextStatesIndex(c), i1);
        contextSetStatesIndex(c, n);
      } else {
        final int n2 = contextStatesIndex(c) + (_index2Units[i2] << 1);
        final int u = _index2Units[i1] - _index2Units[i2];
        freeUnits(n2, u);
      }
    }
    contextSetNumStates(c, size);
    return contextStates(c);
  }

  List<_State>? expandStates(int c) {
    List<_State> st = contextStates(c);
    final int ns = st.length;
    if (ns == 1) {
      final _State s = st[0];
      final int n = allocUnits(1);
      if (n == 0) return null;
      contextSetStatesIndex(c, n);
      st = _StateSlice(states, n, 1);
      st[0] = _State(sym: s.sym, freq: s.freq, succ: s.succ);
    } else if ((ns & 1) == 0) {
      final int u = ns >> 1;
      final int i1 = _units2Index[u];
      final int i2 = _units2Index[u + 1];
      if (i1 != i2) {
        final int n = allocUnits(i2);
        if (n == 0) return null;
        for (int k = 0; k < ns; k++) {
          states[n + k] =
              _State(sym: st[k].sym, freq: st[k].freq, succ: st[k].succ);
        }
        addFreeBlock(contextStatesIndex(c), i1);
        contextSetStatesIndex(c, n);
        st = _StateSlice(states, n, ns);
      }
    }
    contextSetNumStates(c, ns + 1);
    return contextStates(c);
  }

  _State findState(int c, int sym) {
    final List<_State> st = contextStates(c);
    int i = 0;
    for (; i < st.length; i++) {
      if ((st[i].sym & 0xFF) == (sym & 0xFF)) break;
    }
    return st[i];
  }
}

class _Model {
  int maxOrder = 0;
  int restoreMethod = 0;
  int orderFall = 0;
  int initRL = 0;
  int runLength = 0;
  int prevSuccess = 0;
  int escCount = 0;
  int prevSym = 0;
  int initEsc = 0;
  int c = 0;
  final _RangeCoder rc = _RangeCoder();
  final _SubAllocator a = _SubAllocator();
  final Uint8List charMask = Uint8List(256);
  final List<int> binSumm =
      List<int>.filled(_binSummRowDivisors.length * 64, 0);
  final List<List<_See2Context>> see2Cont = List<List<_See2Context>>.generate(
    24,
    (int i) => List<_See2Context>.generate(
      32,
      (_) => _See2Context(
        summ: _seeRowInitialSummaries[i],
        shift: 3,
        count: 7,
      ),
    ),
  );
  final List<int> ibuf = List<int>.filled(256, 0);
  Stopwatch? _stopwatch;
  int _timeoutMicros = 0;
  int _timeoutTicks = 0;

  void setDeadline(Stopwatch stopwatch, Duration timeout) {
    _stopwatch = stopwatch;
    _timeoutMicros = timeout.inMicroseconds;
    rc.shouldAbort = isTimedOut;
  }

  bool isTimedOut() {
    final Stopwatch? stopwatch = _stopwatch;
    if (stopwatch == null) return false;
    if (((_timeoutTicks++) & 0x3FF) != 0) return false;
    return stopwatch.elapsedMicroseconds > _timeoutMicros;
  }

  void restart() {
    for (int i = 0; i < 256; i++) {
      charMask[i] = 0;
    }
    escCount = 1;
    if (maxOrder < 12) {
      initRL = -maxOrder - 1;
    } else {
      initRL = -12 - 1;
    }
    orderFall = maxOrder;
    runLength = initRL;
    prevSuccess = 0;
    a.restart();
    c = a.newContextSize(256);
    a.contextSetFlags(c, 0);
    a.contextSetSummFreq(c, 257);
    final List<_State> states = a.contextStates(c);
    for (int i = 0; i < states.length; i++) {
      states[i].sym = i & 0xFF;
      states[i].freq = 1;
    }
    for (int row = 0; row < _binSummRowDivisors.length; row++) {
      final int divisor = _binSummRowDivisors[row];
      for (int column = 0; column < 8; column++) {
        final int esc = _initBinEsc[column];
        final int n = _binScale - esc ~/ divisor;
        for (int k = column; k < 64; k += 8) {
          binSumm[row * 64 + k] = n & 0xFFFF;
        }
      }
    }
    for (int i = 0; i < see2Cont.length; i++) {
      for (int j = 0; j < 32; j++) {
        see2Cont[i][j] = _See2Context(
          summ: _seeRowInitialSummaries[i],
          shift: 3,
          count: 7,
        );
      }
    }
  }

  bool init(_ByteReader br,
      {required bool reset,
      required int maxOrder,
      required int memoryBytes,
      required int restoreMethod}) {
    if (!rc.init(br)) return false;
    if (!reset) return true;
    a.init(memoryBytes);
    this.maxOrder = maxOrder;
    this.restoreMethod = restoreMethod;
    prevSym = 0;
    c = 0;
    return true;
  }

  _State? rescale(int cctx, _State s) {
    if (s.freq <= _maxFreq) return s;
    s.freq += 4;
    final List<_State> states = a.contextStates(cctx);
    int escFreq = a.contextSummFreq(cctx) + 4;
    int summFreq = 0;
    int contextFlags = a.contextFlags(cctx) & 0x10;
    int highBits = 0;
    for (int i = 0; i < states.length; i++) {
      int f = states[i].freq;
      escFreq -= f;
      if (orderFall != 0) f++;
      f >>= 1;
      if (f > 0 && (states[i].sym & 0xFF) >= 64) {
        highBits = 0x08;
      }
      summFreq += f;
      states[i].freq = f;
      if (i == 0 || f <= states[i - 1].freq) continue;
      int j = i - 1;
      while (j > 0 && f > states[j - 1].freq) {
        j--;
      }
      final _State t = states[i];
      for (int k = i; k > j; k--) {
        states[k] = states[k - 1];
      }
      states[j] = t;
    }
    int i = states.length - 1;
    while (states[i].freq == 0) {
      i--;
      escFreq++;
    }
    if (i != states.length - 1) {
      a.shrinkStates(cctx, states, i + 1);
    }
    s = a.contextStates(cctx)[0];
    if (i == 0) {
      a.contextSetFlags(
          cctx, contextFlags | (((s.sym & 0xFF) >= 64) ? 0x08 : 0));
      while (true) {
        s.freq -= s.freq >> 1;
        escFreq >>= 1;
        if (escFreq <= 1) return s;
      }
    }
    summFreq += escFreq - (escFreq >> 1);
    a.contextSetFlags(cctx, contextFlags | highBits | 0x04);
    a.contextSetSummFreq(cctx, summFreq);
    return s;
  }

  (_State?, bool) decodeBinSymbol(int cctx) {
    final List<_State> css = a.contextStates(cctx);
    final _State s = css[0];
    final int ns = a.contextNumStates(a.contextSuffix(cctx));
    int idx = prevSuccess + _ns2BSIndex[ns - 1] + ((runLength >> 26) & 0x20);
    idx += a.contextFlags(cctx);
    int freqClass = _binSummFreqIndex[(s.freq - 1).clamp(0, 255).toInt()];
    if (freqClass >= _binSummRowDivisors.length) {
      freqClass = _binSummRowDivisors.length - 1;
    }
    final int bix = freqClass * 64 + idx;
    int bs = binSumm[bix];
    final int mean = (bs + (1 << (_periodBits - 2))) >> _periodBits;
    if (rc.currentCount(_binScale) < bs) {
      if (!rc.decode(0, bs)) return (null, false);
      if (s.freq < 128) s.freq++;
      binSumm[bix] = (bs + (1 << _intBits) - mean) & 0xFFFF;
      prevSuccess = 1;
      runLength++;
      return (s, true);
    }
    if (!rc.decode(bs, _binScale)) return (null, false);
    bs -= mean;
    binSumm[bix] = bs & 0xFFFF;
    initEsc = _expEscape[((bs >> 10).clamp(0, 15)).toInt()];
    charMask[s.sym & 0xFF] = escCount;
    prevSuccess = 0;
    return (null, true);
  }

  (_State?, bool) decodeSymbol1(int cctx) {
    final List<_State> states = a.contextStates(cctx);
    int scale = a.contextSummFreq(cctx);
    if (scale == 0) return (null, false);
    final int count = rc.currentCount(scale);
    prevSuccess = 0;
    int n = 0;
    for (int i = 0; i < states.length; i++) {
      final _State s = states[i];
      n += s.freq;
      if (n <= count) continue;
      if (!rc.decode(n - s.freq, n)) return (null, false);
      s.freq += 4;
      a.contextSetSummFreq(cctx, scale + 4);
      if (i == 0) {
        if (2 * n > scale) {
          prevSuccess = 1;
          runLength++;
        }
      } else {
        if (s.freq <= states[i - 1].freq) {
          return (s, true);
        }
        final _State tmp = states[i - 1];
        states[i - 1] = states[i];
        states[i] = tmp;
        return (rescale(cctx, states[i - 1])!, true);
      }
      return (rescale(cctx, s)!, true);
    }
    for (int j = 0; j < states.length; j++) {
      charMask[states[j].sym & 0xFF] = escCount;
    }
    if (!rc.decode(n, scale)) return (null, false);
    return (null, true);
  }

  _See2Context? makeEscFreq(int cctx, int numMasked) {
    final int ns = a.contextNumStates(cctx);
    if (ns == 256) return null;
    final int suffix = a.contextSuffix(cctx);
    if (suffix <= 0) return null;
    final int nsByte = ns - 1;
    final int suffixNsByte = a.contextNumStates(suffix) - 1;
    int i = a.contextFlags(cctx) & 0x1F;
    if (11 * ns < a.contextSummFreq(cctx)) i++;
    if ((nsByte << 1) < suffixNsByte + numMasked) i += 2;
    return see2Cont[_ns2Index[nsByte]][i];
  }

  (_State?, bool) decodeSymbol2(int cctx, int numMasked) {
    final _See2Context? see = makeEscFreq(cctx, numMasked);
    int scale = see?.mean() ?? 1;
    int i = 0;
    int hi = 0;
    final List<_State> states = a.contextStates(cctx);
    final int n = states.length - numMasked;
    for (int j = 0; j < n; j++) {
      if (isTimedOut()) return (null, false);
      while (charMask[states[i].sym & 0xFF] == escCount) {
        i++;
      }
      hi += states[i].freq;
      ibuf[j] = i;
      i++;
    }
    scale += hi;
    final int count = rc.currentCount(scale);
    if (count >= scale) return (null, false);
    if (count >= hi) {
      if (!rc.decode(hi, scale)) return (null, false);
      if (see != null) {
        see.summ = (see.summ + scale) & 0xFFFF;
      }
      for (int j = 0; j < n; j++) {
        charMask[states[ibuf[j]].sym & 0xFF] = escCount;
      }
      return (null, true);
    }
    hi = states[ibuf[0]].freq;
    int nn = 0;
    while (hi <= count) {
      if (isTimedOut()) return (null, false);
      nn++;
      hi += states[ibuf[nn]].freq;
    }
    final _State s = states[ibuf[nn]];
    if (!rc.decode(hi - s.freq, hi)) return (null, false);
    see?.update();
    escCount++;
    runLength = initRL;
    s.freq += 4;
    a.contextIncSummFreq(cctx, 4);
    return (rescale(cctx, s)!, true);
  }

  int createSuccessors(int cctx, _State s, _State? ss) {
    final List<_State> sl = <_State>[];
    if (orderFall != 0) {
      sl.add(s);
    }
    int c = cctx;
    for (int suff = a.contextSuffix(c); suff > 0; suff = a.contextSuffix(c)) {
      if (isTimedOut()) return 0;
      c = suff;
      ss ??= a.findState(c, s.sym);
      if (ss.succ != s.succ) {
        c = _succContext(ss.succ);
        break;
      }
      sl.add(ss);
      ss = null;
    }
    if (sl.isEmpty) return c;
    final _State up = _State();
    up.sym = a.succByte(s.succ);
    up.succ = a.nextByteAddr(s.succ);
    final List<_State> states = a.contextStates(c);
    if (states.length > 1) {
      final _State fs = a.findState(c, up.sym);
      final int cf = fs.freq - 1;
      final int s0 = a.contextSummFreq(c) - states.length - cf;
      if (2 * cf <= s0) {
        up.freq = (5 * cf > s0) ? 2 : 1;
      } else {
        up.freq = 1 + ((2 * cf + 3 * s0 - 1) ~/ (2 * s0));
      }
    } else {
      up.freq = states[0].freq;
    }
    for (int k = sl.length - 1; k >= 0; k--) {
      if (isTimedOut()) return 0;
      final int nc = a.newContext(
        up,
        c,
        flags: (((s.sym & 0xFF) >= 64) ? 0x10 : 0) |
            (((up.sym & 0xFF) >= 64) ? 0x08 : 0),
      );
      if (nc == 0) return 0;
      sl[k].succ = nc;
      c = nc;
    }
    return c;
  }

  int update(int minC, int maxC, _State s) {
    if (isTimedOut()) return 0;
    if (orderFall == 0 && s.succ > 0) {
      return s.succ;
    }
    if (escCount == 0) {
      escCount = 1;
      for (int i = 0; i < 256; i++) {
        charMask[i] = 0;
      }
    }
    _State? ss;
    if (s.freq < _maxFreq ~/ 4 && a.contextSuffix(minC) > 0) {
      final int cx = a.contextSuffix(minC);
      final List<_State> states = a.contextStates(cx);
      int i = 0;
      if (states.length > 1) {
        while ((states[i].sym & 0xFF) != (s.sym & 0xFF)) {
          i++;
        }
        if (i > 0 && states[i].freq >= states[i - 1].freq) {
          final _State tmp = states[i - 1];
          states[i - 1] = states[i];
          states[i] = tmp;
          i--;
        }
        if (states[i].freq < _maxFreq - 9) {
          states[i].freq += 2;
          a.contextIncSummFreq(cx, 2);
        }
      } else if (states[0].freq < 32) {
        states[0].freq++;
      }
      ss = states[i];
    }
    if (orderFall == 0) {
      final int nc = createSuccessors(minC, s, ss);
      s.succ = nc;
      return nc;
    }
    int succ = a.pushByte(s.sym & 0xFF);
    if (succ == 0) return 0;
    late int newC;
    if (s.succ == 0) {
      s.succ = succ;
      newC = minC;
    } else {
      if (s.succ > 0) {
        newC = s.succ;
      } else {
        final int cs = createSuccessors(minC, s, ss);
        if (cs == 0) return 0;
        newC = cs;
      }
      orderFall--;
      if (orderFall == 0) {
        succ = newC;
        if (maxC != minC) {
          a.popByte();
        }
      }
    }
    final int n = a.contextNumStates(minC);
    final int s0 = a.contextSummFreq(minC) - n - (s.freq - 1);
    int cx = maxC;
    while (cx != minC) {
      if (isTimedOut()) return 0;
      int summFreq;
      final List<_State>? states = a.expandStates(cx);
      if (states == null) return 0;
      final int ns = states.length - 1;
      if (ns != 1) {
        summFreq = a.contextSummFreq(cx);
        if (4 * ns <= n && summFreq <= 8 * ns) summFreq += 2;
        if (2 * ns < n) summFreq++;
      } else {
        final _State p = states[0];
        if (p.freq < _maxFreq ~/ 4 - 1) {
          p.freq += p.freq;
        } else {
          p.freq = _maxFreq - 4;
        }
        summFreq = p.freq + initEsc;
        if (n > 3) summFreq++;
      }
      final int cf = 2 * s.freq * (summFreq + 6);
      final int sf = s0 + summFreq;
      int freq;
      if (cf >= 6 * sf) {
        if (cf >= 15 * sf) {
          freq = 7;
        } else if (cf >= 12 * sf) {
          freq = 6;
        } else if (cf >= 9 * sf) {
          freq = 5;
        } else {
          freq = 4;
        }
        summFreq += freq;
      } else {
        if (cf >= 4 * sf) {
          freq = 3;
        } else if (cf > sf) {
          freq = 2;
        } else {
          freq = 1;
        }
        summFreq += 3;
      }
      states[states.length - 1] =
          _State(sym: s.sym & 0xFF, freq: freq, succ: succ);
      if ((s.sym & 0xFF) >= 64) {
        a.contextSetFlags(cx, a.contextFlags(cx) | 0x08);
      }
      a.contextSetSummFreq(cx, summFreq);
      cx = a.contextSuffix(cx);
    }
    return newC;
  }

  int? readByte() {
    if (isTimedOut()) return null;
    if (c == 0) {
      restart();
    }
    int minC = c;
    final int maxC = minC;
    _State? s;
    bool ok = true;
    if (a.contextNumStates(minC) == 1) {
      final (_State? a0, bool o0) = decodeBinSymbol(minC);
      s = a0;
      ok = o0;
    } else {
      final (_State? a1, bool o1) = decodeSymbol1(minC);
      s = a1;
      ok = o1;
    }
    while (s == null && ok) {
      if (isTimedOut()) return null;
      final int n = a.contextNumStates(minC);
      int guard = 0;
      while (a.contextNumStates(minC) == n) {
        if (isTimedOut() || ++guard > a.states.length) return null;
        orderFall++;
        minC = a.contextSuffix(minC);
        if (minC <= 0) return null;
      }
      final (_State? a2, bool o2) = decodeSymbol2(minC, n);
      s = a2;
      ok = o2;
    }
    if (!ok || s == null) return null;
    c = update(minC, maxC, s);
    prevSym = s.sym & 0xFF;
    return s.sym & 0xFF;
  }
}
