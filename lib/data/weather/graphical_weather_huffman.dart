import 'dart:math' as math;
import 'dart:typed_data';
import 'package:orbit/data/bit_buffer.dart';

// "Weather-Huffman" raster decompressor
class GraphicalWeatherHuffman {
  static Uint8List? decode({
    required List<int> payload,
    required int targetCols,
    required int targetRows,
  }) {
    if (payload.isEmpty) return null;
    if (targetCols <= 0 || targetRows <= 0) return null;

    final BitBuffer b = BitBuffer(payload);
    b.align();

    // 17-byte header from the current aligned byte pointer
    // 0x00: size/bounds
    // 0x08: width
    // 0x0A: height
    // 0x0C: maxValue
    // 0x0E: smoothFlag
    // 0x0F: tableCount
    // 0x10: valueMapLen
    final Uint8List hdr = Uint8List.fromList(b.readBytes(0x11));
    if (b.hasError || hdr.length != 0x11) return null;

    int readU16LE(int off) => (hdr[off] | (hdr[off + 1] << 8)) & 0xFFFF;
    int readI32LE(int off) {
      final int v = (hdr[off] |
              (hdr[off + 1] << 8) |
              (hdr[off + 2] << 16) |
              (hdr[off + 3] << 24)) &
          0xFFFFFFFF;
      // Sign-extend
      return (v & 0x80000000) != 0 ? (v - 0x100000000) : v;
    }

    final int sizeCheck = readI32LE(0);
    final int width = readU16LE(8);
    final int height = readU16LE(10);
    final int maxValue = readU16LE(12) & 0xFFFF;
    final int tableCount = hdr[15] & 0xFF;
    final int valueMapLen = hdr[16] & 0xFF;

    // Basic sanity checks
    if (width <= 0 || height <= 0) return null;
    if (width > 0x1000 || height > 0x1000) return null;
    if (maxValue >= 0x100) return null;
    if (tableCount == 0) return null;
    if (sizeCheck > 0 && sizeCheck > payload.length + 0x1000) return null;

    Uint8List? valueMap;
    if (valueMapLen != 0) {
      valueMap = Uint8List.fromList(b.readBytes(valueMapLen));
      if (b.hasError) return null;
    }

    // Build per-value runlength decode tables
    final _RunLengthTableRegistry tables = _RunLengthTableRegistry();
    if (!tables.buildFromStream(b, tableCount)) return null;
    if (b.hasError) return null;

    final int pixelCount = width * height;
    if (pixelCount <= 0) return null;

    // Decode runlengths and write values in Hilbert order
    final Uint8List decoded = Uint8List(pixelCount);
    final List<_GridCoord> hilbertCoords =
        _HilbertCoords.forRect(width, height);

    int coordIndex = 0;
    int filled = 0;
    int v = 0;
    int dir = 1;

    while (filled < pixelCount && !b.hasError) {
      final int run = tables.decodeRunLength(b, v);
      if (run < 0) return null;

      if (run > 0) {
        // Write [v] run times
        for (int i = 0; i < run; i++) {
          if (coordIndex >= hilbertCoords.length) return null;
          final _GridCoord xy = hilbertCoords[coordIndex++];
          decoded[xy.y * width + xy.x] = v & 0xFF;
        }
        filled += run;
      } else {
        v += dir;
        if (v < 0) v = 0;
        if (v > maxValue) v = maxValue;
        continue;
      }

      // Decide next direction/value step
      if (v == 0) {
        dir = 1;
      } else if (v == maxValue) {
        dir = -1;
      } else {
        final int bit = b.readBits(1);
        if (b.hasError) return null;
        dir = (bit == 0) ? 1 : -1;
      }
      v += dir;
      if (v < 0) v = 0;
      if (v > maxValue) v = maxValue;
    }

    // Optional value remap
    Uint8List plane = decoded;
    if (valueMap != null && valueMap.isNotEmpty) {
      final Uint8List mapped = Uint8List(pixelCount);
      for (int i = 0; i < pixelCount; i++) {
        final int idx = plane[i] & 0xFF;
        mapped[i] = (idx < valueMap.length) ? valueMap[idx] : 0;
      }
      plane = mapped;
    }

    // Fallback: width/height already match target
    if (width != targetCols || height != targetRows) {
      plane = _nearestNeighborScale(
        src: plane,
        srcW: width,
        srcH: height,
        dstW: targetCols,
        dstH: targetRows,
      );
    }

    return plane;
  }

  static Uint8List _nearestNeighborScale({
    required Uint8List src,
    required int srcW,
    required int srcH,
    required int dstW,
    required int dstH,
  }) {
    final Uint8List out = Uint8List(dstW * dstH);
    if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return out;

    // Avoid the anchor bias by sampling pixel centers
    int mapCenter(int dst, int dstSize, int srcSize) {
      if (srcSize == 1) return 0;
      final double srcPos = ((dst + 0.5) * srcSize / dstSize) - 0.5;
      return srcPos.round().clamp(0, srcSize - 1);
    }

    for (int y = 0; y < dstH; y++) {
      final int sy = mapCenter(y, dstH, srcH);
      for (int x = 0; x < dstW; x++) {
        final int sx = mapCenter(x, dstW, srcW);
        out[y * dstW + x] = src[sy * srcW + sx];
      }
    }
    return out;
  }
}

class _GridCoord {
  final int x;
  final int y;
  const _GridCoord(this.x, this.y);
}

// Precomputes Hilbert-order coordinates for a WidthxHeight rectangle
class _HilbertCoords {
  static List<_GridCoord> forRect(int w, int h) {
    if (w <= 0 || h <= 0) return <_GridCoord>[];

    final int order = _bitLength(math.max(w, h));
    final _HilbertStepper stepper =
        _HilbertStepper(width: w, height: h, order: order);
    final int total = w * h;
    final List<_GridCoord> out =
        List<_GridCoord>.filled(total, const _GridCoord(0, 0));
    for (int i = 0; i < total; i++) {
      out[i] = _GridCoord(stepper.x, stepper.y);
      stepper.advance();
    }
    return out;
  }

  static int _bitLength(int v) {
    int x = v;
    int bits = 0;
    while (x != 0) {
      x >>= 1;
      bits++;
    }
    return bits == 0 ? 1 : bits;
  }
}

class _HilbertStepper {
  static const List<int> _stepXByDir = <int>[0, 1, 0, -1];
  static const List<int> _stepYByDir = <int>[1, 0, -1, 0];

  final int width;
  final int height;
  final int maxLevel;

  // State stack, each depth carries [dir0, dir1, dir2, dir3, phase]
  final List<int> _dir0ByDepth;
  final List<int> _dir1ByDepth;
  final List<int> _dir2ByDepth;
  final List<int> _dir3ByDepth;
  final List<int> _phaseByDepth;

  int _depth;
  int x = 0;
  int y = 0;

  _HilbertStepper({
    required this.width,
    required this.height,
    required int order,
  })  : maxLevel = order,
        _dir0ByDepth = List<int>.filled(order + 2, 0),
        _dir1ByDepth = List<int>.filled(order + 2, 0),
        _dir2ByDepth = List<int>.filled(order + 2, 0),
        _dir3ByDepth = List<int>.filled(order + 2, 0),
        _phaseByDepth = List<int>.filled(order + 2, 0),
        _depth = order {
    _dir0ByDepth[_depth] = 0;
    _dir1ByDepth[_depth] = 1;
    _dir2ByDepth[_depth] = 2;
    _dir3ByDepth[_depth] = 3;
  }

  void advance() {
    int depth = _depth;
    if (depth == 0) {
      _depth = 1;
      depth = 1;
    }

    int safety = 0;
    while (true) {
      safety++;
      if (safety > (width * height * 8)) {
        // Prevent infinite loops if state diverges
        return;
      }
      if (depth == 0) {
        _depth = 1;
        depth = 1;
      }

      final int s = depth;
      switch (_phaseByDepth[s]) {
        case 0:
          _depth = s - 1;
          _phaseByDepth[s] = 1;
          _dir0ByDepth[_depth] = _dir1ByDepth[s];
          _dir1ByDepth[_depth] = _dir0ByDepth[s];
          _dir2ByDepth[_depth] = _dir3ByDepth[s];
          _dir3ByDepth[_depth] = _dir2ByDepth[s];
          _phaseByDepth[_depth] = 0;
          depth = _depth;
          continue;
        case 1:
          _phaseByDepth[s] = 2;
          if (_move(_dir1ByDepth[s])) return;
          depth = _depth;
          continue;
        case 2:
          _depth = s - 1;
          _phaseByDepth[s] = 3;
          _dir0ByDepth[_depth] = _dir0ByDepth[s];
          _dir1ByDepth[_depth] = _dir1ByDepth[s];
          _dir2ByDepth[_depth] = _dir2ByDepth[s];
          _dir3ByDepth[_depth] = _dir3ByDepth[s];
          _phaseByDepth[_depth] = 0;
          depth = _depth;
          continue;
        case 3:
          _phaseByDepth[s] = 4;
          if (_move(_dir0ByDepth[s])) return;
          depth = _depth;
          continue;
        case 4:
          _depth = s - 1;
          _phaseByDepth[s] = 5;
          _dir0ByDepth[_depth] = _dir0ByDepth[s];
          _dir1ByDepth[_depth] = _dir1ByDepth[s];
          _dir2ByDepth[_depth] = _dir2ByDepth[s];
          _dir3ByDepth[_depth] = _dir3ByDepth[s];
          _phaseByDepth[_depth] = 0;
          depth = _depth;
          continue;
        case 5:
          _phaseByDepth[s] = 6;
          if (_move(_dir3ByDepth[s])) return;
          depth = _depth;
          continue;
        case 6:
          _depth = s - 1;
          _phaseByDepth[s] = 7;
          _dir0ByDepth[_depth] = _dir3ByDepth[s];
          _dir1ByDepth[_depth] = _dir2ByDepth[s];
          _dir2ByDepth[_depth] = _dir1ByDepth[s];
          _dir3ByDepth[_depth] = _dir0ByDepth[s];
          _phaseByDepth[_depth] = 0;
          depth = _depth;
          continue;
        case 7:
          _depth = s + 1;
          if (_depth > maxLevel) {
            return;
          }
          depth = _depth;
          continue;
        default:
          depth = _depth;
          continue;
      }
    }
  }

  bool _move(int dir) {
    final int direction = dir & 0x3;
    x += _stepXByDir[direction];
    y += _stepYByDir[direction];
    return x >= 0 && x < width && y >= 0 && y < height;
  }
}

class _RunLengthTableRegistry {
  // Per-table: Raw 3-byte entries [bitlen, code, symbol]
  final List<Uint8List?> _runLengthTablesByIndex =
      List<Uint8List?>.filled(256, null);
  final Uint8List _variableBitsSelectorByTable = Uint8List(256);

  // Static built-in table sets (selector values 0/1/2)
  static final List<Uint8List> _builtinRunLengthTableSet0 = <Uint8List>[
    _builtinSet0Table0,
    _builtinSet0Table1,
    _builtinSet0Table1,
    _builtinSet0Table2,
    _builtinSet0Table2,
    _builtinSet0Table2,
    _builtinSet0Table2,
    _builtinSet0Table3,
  ];
  static final List<Uint8List> _builtinRunLengthTableSet1 = <Uint8List>[
    _builtinSet1Table0,
    _builtinSet1Table0,
    _builtinSet1Table0,
    _builtinSet1Table1,
    _builtinSet1Table1,
    _builtinSet1Table1,
    _builtinSet1Table1,
    _builtinSet1Table2,
  ];
  static final List<Uint8List> _builtinRunLengthTableSet2 = <Uint8List>[
    _builtinSet2Table0,
    _builtinSet2Table1,
    _builtinSet2Table1,
    _builtinSet2Table2,
    _builtinSet2Table2,
    _builtinSet2Table2,
    _builtinSet2Table2,
    _builtinSet2Table3,
  ];

  bool buildFromStream(BitBuffer b, int tableCount) {
    for (int i = 0; i < tableCount; i++) {
      final int builtinSelector = b.readBits(2);
      if (b.hasError) return false;

      final int tableVariantIndex = i > 6 ? 7 : i;
      Uint8List? table;

      switch (builtinSelector) {
        case 0:
          table = _builtinRunLengthTableSet0[tableVariantIndex];
          break;
        case 1:
          table = _builtinRunLengthTableSet1[tableVariantIndex];
          break;
        case 2:
          table = _builtinRunLengthTableSet2[tableVariantIndex];
          break;
        case 3:
          table = _buildCustomTable(b);
          break;
        default:
          return false;
      }

      if (table == null || table.isEmpty) return false;
      _runLengthTablesByIndex[i] = table;

      final int key = b.readBits(3) & 0x7;
      if (b.hasError) return false;
      _variableBitsSelectorByTable[i] = key;
    }
    return true;
  }

  int decodeRunLength(BitBuffer b, int tableIndex) {
    final Uint8List? table = _runLengthTablesByIndex[tableIndex];
    if (table == null || table.isEmpty) return -1;

    int bitsRead = 0;
    int code = 0;

    for (int off = 0; off + 2 < table.length; off += 3) {
      final int bitLen = table[off] & 0xFF;
      if (bitLen == 0) break;

      while (bitsRead < bitLen) {
        final int bit = b.readBits(1);
        if (b.hasError) return -1;
        bitsRead++;
        code = ((code << 1) | (bit & 1)) & 0xFFFFFFFF;
      }

      final int want = table[off + 1] & 0xFF;
      if ((code & ((1 << bitLen) - 1)) == want) {
        final int sym = table[off + 2] & 0xFF;
        if (sym == 0xFD) return -1;

        if (sym == 0xFE) {
          final int v8 = b.readBits(8);
          if (b.hasError) return -1;
          final int inner = decodeRunLength(b, tableIndex);
          if (inner < 0) return -1;
          return inner + v8 * 0x40 + 0x40;
        }

        if (sym == 0xFF) {
          final int k = _variableBitsSelectorByTable[tableIndex] & 0x7;
          // If bit K is 0 and next bit is 0, choose A, otherwise choose B
          final bool chooseA = (((0xE9 >> k) & 1) == 0) && (b.readBits(1) == 0);
          if (b.hasError) return -1;
          final int bits = chooseA
              ? _variableRunLengthBitsPrimary[k]
              : _variableRunLengthBitsFallback[k];
          if (bits <= 0) return 0;
          return b.readBits(bits);
        }

        return sym;
      }
    }

    return -1;
  }

  Uint8List? _buildCustomTable(BitBuffer b) {
    b.skipBits(3);
    if (b.hasError) return null;

    final int hasEntries = b.readBits(1);
    if (b.hasError) return null;

    final List<_CustomEntry> entries = <_CustomEntry>[];
    if (hasEntries == 1) {
      int sym = -1;
      int order = 0;
      while (true) {
        final int len = b.readBits(3);
        if (b.hasError) return null;
        if (len > 0) {
          entries.add(_CustomEntry(len: len, symbol: sym, order: order));
        }
        order++;

        // Symbol progression: -1, -2, 0, 1, 2, ...
        if (sym == -1) {
          sym = -2;
        } else if (sym == -2) {
          sym = 0;
        } else {
          sym = sym + 1;
        }

        final int cont = b.readBits(1);
        if (b.hasError) return null;
        if (cont != 1) break;
      }
    }

    if (entries.isEmpty) {
      // Empty/invalid custom table
      return Uint8List.fromList(<int>[0, 0, 0]);
    }

    // Make ordering explicit
    entries.sort((a, b) {
      final int byLen = a.len.compareTo(b.len);
      if (byLen != 0) return byLen;
      return a.order.compareTo(b.order);
    });

    int code = 0;
    int curLen = 1;
    for (final e in entries) {
      if (curLen < e.len) {
        code <<= (e.len - curLen);
        curLen = e.len;
      }
      e.code = code & 0xFF;
      code = (code + 1) & 0xFF;
    }

    final List<int> raw = <int>[];
    for (final e in entries) {
      raw.add(e.len & 0xFF);
      raw.add(e.code & 0xFF);
      raw.add(e.symbol & 0xFF);
    }
    raw.addAll(<int>[0, 0, 0]);
    return Uint8List.fromList(raw);
  }
}

class _CustomEntry {
  final int len;
  final int symbol;
  final int order;
  int code = 0;
  _CustomEntry({required this.len, required this.symbol, required this.order});
}

// Bits-per-value tables
const List<int> _variableRunLengthBitsPrimary = <int>[0, 3, 2, 0, 2, 0, 0, 0];
const List<int> _variableRunLengthBitsFallback = <int>[6, 6, 6, 5, 5, 4, 3, 2];

// Built-in runlength tables
final Uint8List _builtinSet0Table0 = Uint8List.fromList(<int>[
  //
  0x01, 0x00, 0xFE, 0x04, 0x08, 0xFF, 0x04, 0x09, 0x01, 0x04, 0x0A, 0x02,
  0x04, 0x0B, 0x03, 0x04, 0x0C, 0x04, 0x04, 0x0D, 0x05, 0x04, 0x0E, 0x06,
  0x04, 0x0F, 0x07, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet0Table1 = Uint8List.fromList(<int>[
  //
  0x03, 0x00, 0xFF, 0x03, 0x01, 0xFE, 0x03, 0x02, 0x00, 0x03, 0x03, 0x01,
  0x03, 0x04, 0x02, 0x03, 0x05, 0x03, 0x03, 0x06, 0x04, 0x03, 0x07, 0x05,
  0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet0Table2 = Uint8List.fromList(<int>[
  //
  0x02, 0x00, 0x00, 0x02, 0x01, 0x01, 0x02, 0x02, 0x02, 0x03, 0x06, 0xFF,
  0x03, 0x07, 0xFE, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet0Table3 = Uint8List.fromList(<int>[
  //
  0x02, 0x00, 0x01, 0x02, 0x01, 0x02, 0x02, 0x02, 0x03, 0x03, 0x06, 0xFF,
  0x03, 0x07, 0xFE, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet1Table0 = Uint8List.fromList(<int>[
  //
  0x01, 0x00, 0xFF, 0x01, 0x01, 0xFE, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet1Table1 = Uint8List.fromList(<int>[
  //
  0x01, 0x00, 0xFF, 0x03, 0x04, 0x00, 0x03, 0x05, 0x01, 0x03, 0x06, 0x02,
  0x03, 0x07, 0xFE, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet1Table2 = Uint8List.fromList(<int>[
  //
  0x01, 0x00, 0xFF, 0x03, 0x04, 0x01, 0x03, 0x05, 0x02, 0x03, 0x06, 0x03,
  0x03, 0x07, 0xFE, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet2Table0 = Uint8List.fromList(<int>[
  //
  0x02, 0x00, 0xFE, 0x02, 0x01, 0xFF, 0x04, 0x08, 0x01, 0x04, 0x09, 0x02,
  0x04, 0x0A, 0x03, 0x04, 0x0B, 0x04, 0x04, 0x0C, 0x05, 0x04, 0x0D, 0x06,
  0x04, 0x0E, 0x07, 0x04, 0x0F, 0x08, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet2Table1 = Uint8List.fromList(<int>[
  //
  0x02, 0x00, 0xFF, 0x02, 0x01, 0xFE, 0x04, 0x08, 0x00, 0x04, 0x09, 0x01,
  0x04, 0x0A, 0x02, 0x04, 0x0B, 0x03, 0x04, 0x0C, 0x04, 0x04, 0x0D, 0x05,
  0x04, 0x0E, 0x06, 0x04, 0x0F, 0x07, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet2Table2 = Uint8List.fromList(<int>[
  //
  0x02, 0x00, 0xFF, 0x03, 0x02, 0xFE, 0x03, 0x03, 0x00, 0x03, 0x04, 0x01,
  0x03, 0x05, 0x02, 0x03, 0x06, 0x03, 0x03, 0x07, 0x04, 0x00, 0x00, 0x00,
]);

final Uint8List _builtinSet2Table3 = Uint8List.fromList(<int>[
  //
  0x02, 0x00, 0xFF, 0x03, 0x02, 0xFE, 0x03, 0x03, 0x01, 0x03, 0x04, 0x02,
  0x03, 0x05, 0x03, 0x03, 0x06, 0x04, 0x03, 0x07, 0x05, 0x00, 0x00, 0x00,
]);
