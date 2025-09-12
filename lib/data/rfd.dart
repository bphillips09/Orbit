// Reliable File Delivery (RFD) handler
import 'dart:typed_data';
import 'package:orbit/logging.dart';

class RfdMetadata {
  final String? fileName;
  final int? expectedSize;
  final int? blockSize;
  final int? fileId;
  final int? compressionMode;
  final List<int> raw;

  const RfdMetadata(
      {this.fileName,
      this.expectedSize,
      this.blockSize,
      this.fileId,
      this.compressionMode,
      required this.raw});

  @override
  String toString() {
    return 'RfdMetadata(fileName: ${fileName ?? 'null'}, '
        'expectedSize: ${expectedSize?.toString() ?? 'null'}, '
        'blockSize: ${blockSize?.toString() ?? 'null'}, '
        'fileId: ${fileId?.toString() ?? 'null'}, '
        'compression: ${compressionMode?.toString() ?? 'null'}, '
        'rawLen: ${raw.length})';
  }
}

// RFD session
class RfdSession {
  RfdMetadata metadata;
  final List<int> _seqBuffer = <int>[];
  Uint8List? _fileBuffer;
  List<int>? _receivedBlockLengths;
  int _receivedSize = 0;
  final Map<int, int> _receivedAtOffset = <int, int>{};
  final DateTime startedAt = DateTime.now();
  DateTime lastUpdated = DateTime.now();
  bool _completed = false;

  RfdSession(this.metadata) {
    _maybeAllocate();
  }

  void _maybeAllocate() {
    if (_fileBuffer != null) return;
    if (metadata.expectedSize == null || metadata.expectedSize! <= 0) return;
    if (metadata.blockSize == null || metadata.blockSize! <= 0) return;
    final int total = metadata.expectedSize!;
    final int blk = metadata.blockSize!;
    _fileBuffer = Uint8List(total);
    final int numBlocks = (total + blk - 1) ~/ blk;
    _receivedBlockLengths = List<int>.filled(numBlocks, 0);
    // If we had sequential bytes before we knew block metadata, drop them
    if (_seqBuffer.isNotEmpty) {
      logger.d(
          'RFD: dropping ${_seqBuffer.length} bytes of sequential buffer after allocation');
      _seqBuffer.clear();
    }
  }

  bool get isCompleted => _completed;
  int get receivedSize =>
      _fileBuffer != null ? _receivedSize : _seqBuffer.length;
  List<int> get bytes {
    if (_fileBuffer != null) {
      return List<int>.unmodifiable(_fileBuffer!);
    }
    return List<int>.unmodifiable(_seqBuffer);
  }

  // Append a new contiguous chunk of file bytes
  void addChunk(List<int> data) {
    if (_completed) return;
    if (data.isEmpty) return;
    if (_fileBuffer != null) {
      logger.w('RFD: addChunk called after block mode active; ignoring');
      return;
    }
    if (metadata.expectedSize != null && metadata.expectedSize! > 0) {
      final int remaining = metadata.expectedSize! - _seqBuffer.length;
      if (remaining <= 0) {
        _completed = true;
        return;
      }
      final int toCopy = data.length > remaining ? remaining : data.length;
      if (toCopy > 0) {
        _seqBuffer.addAll(data.sublist(0, toCopy));
      }
    } else {
      _seqBuffer.addAll(data);
    }
    lastUpdated = DateTime.now();
    if (metadata.expectedSize != null &&
        _seqBuffer.length >= metadata.expectedSize!) {
      _completed = true;
    }
  }

  // Add payload at a specific byte offset
  void addAtOffset(int offsetBytes, List<int> data) {
    if (_completed) return;
    if (data.isEmpty) return;
    lastUpdated = DateTime.now();

    // Ensure allocation
    if (_fileBuffer == null || _receivedBlockLengths == null) {
      logger.w(
          'RFD: offset data received but buffer not allocated; using sequential fallback');
      addChunk(data);
      return;
    }

    final int total = metadata.expectedSize!;
    if (offsetBytes >= total) {
      logger.w('RFD: write offset $offsetBytes beyond total $total');
      return;
    }

    int lenToCopy = data.length;
    final int maxLen = total - offsetBytes;
    if (lenToCopy > maxLen) lenToCopy = maxLen;

    // Deduplicate
    final int prevLen = _receivedAtOffset[offsetBytes] ?? 0;
    if (lenToCopy <= prevLen) {
      logger.t(
          'RFD: duplicate payload at offset=$offsetBytes (len=$lenToCopy <= prev=$prevLen), ignoring');
      return;
    }

    // Copy bytes into preallocated buffer
    for (int i = 0; i < lenToCopy; i++) {
      _fileBuffer![offsetBytes + i] = data[i];
    }

    // Update per-block receipt if aligned
    final int blockSize = metadata.blockSize!;
    if (offsetBytes % blockSize == 0) {
      final int blockIndex = offsetBytes ~/ blockSize;
      if (blockIndex >= 0 && blockIndex < _receivedBlockLengths!.length) {
        _receivedBlockLengths![blockIndex] = lenToCopy;
      }
    }

    _receivedAtOffset[offsetBytes] = lenToCopy;
    final int delta = lenToCopy - prevLen;
    _receivedSize += delta;

    logger.t(
        'RFD: wrote offset=$offsetBytes len=$lenToCopy total=$_receivedSize/$total');

    if (_receivedSize >= total) {
      _completed = true;
    }
  }

  // Update metadata fields
  void updateMetadata({String? fileName, int? expectedSize, int? blockSize}) {
    final String? newName = fileName ?? metadata.fileName;
    final int? newExpected = expectedSize ?? metadata.expectedSize;
    final int? newBlock = blockSize ?? metadata.blockSize;
    metadata = RfdMetadata(
        fileName: newName,
        expectedSize: newExpected,
        blockSize: newBlock,
        fileId: metadata.fileId,
        compressionMode: metadata.compressionMode,
        raw: metadata.raw);
    _maybeAllocate();
    if (metadata.expectedSize != null &&
        receivedSize >= metadata.expectedSize!) {
      _completed = true;
    }
  }

  // Force-complete the session
  void markComplete() {
    _completed = true;
  }
}

// Collector managing at most one active RFD session
class RfdCollector {
  final Map<int, RfdSession> _sessions = <int, RfdSession>{};
  final Map<int, List<List<int>>> _stagingByFile = <int, List<List<int>>>{};
  RfdMetadata? _pendingMeta;

  bool get inProgress => _sessions.values.any((s) => !s.isCompleted);
  RfdSession? get current => _sessions.values
      .cast<RfdSession?>()
      .firstWhere((s) => s != null, orElse: () => null);

  // Receive metadata, bind to a fileId when first chunk arrives
  void start(RfdMetadata metadata) {
    _pendingMeta = metadata;
    logger.d('RFD: received metadata $metadata');
  }

  // Ensure there is a session, if none, create a placeholder one so data can begin buffering
  void ensureSession(
      {required int fileId,
      RfdMetadata? metadata,
      int? expectedSize,
      String? fileName,
      int? blockSize}) {
    var s = _sessions[fileId];
    if (s == null) {
      s = RfdSession(metadata ??
          const RfdMetadata(
              fileName: null,
              expectedSize: null,
              blockSize: null,
              fileId: null,
              raw: <int>[]));
      _sessions[fileId] = s;
      logger.d('RFD: created placeholder session for fileId=$fileId');
    }
    if (expectedSize != null || fileName != null || blockSize != null) {
      s.updateMetadata(
          fileName: fileName, expectedSize: expectedSize, blockSize: blockSize);
    }
  }

  // Append chunk data to the current session, if any
  bool addData(List<int> data) {
    final sess = current;
    if (sess == null) {
      logger.t('RFD: data with no session; dropping ${data.length}');
      return false;
    }
    sess.addChunk(data);
    return sess.isCompleted;
  }

  // Parse block header and add by index (fallback append for now)
  bool addBlockFromAu(List<int> auChunk, {int headerLen = 5}) {
    if (auChunk.length <= headerLen) {
      logger.t('RFD: block AU too small: ${auChunk.length}');
      return false;
    }
    final int fileId = ((auChunk[0] & 0xFF) << 8) | (auChunk[1] & 0xFF);
    final int offUnits = ((auChunk[2] & 0xFF) << 16) |
        ((auChunk[3] & 0xFF) << 8) |
        (auChunk[4] & 0xFF);
    final int byteOffset = offUnits << 3;
    final List<int> payload = auChunk.sublist(headerLen);
    final String headerHex = auChunk
        .take(headerLen)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    logger.t(
        'RFD: header=$headerHex fileId=$fileId off=$byteOffset payload=${payload.length}');
    var sess = _sessions[fileId];
    if (sess == null) {
      if (_pendingMeta != null) {
        // Bind pending metadata to this fileId and create session if missing
        final RfdMetadata bound = RfdMetadata(
            fileName: _pendingMeta!.fileName,
            expectedSize: _pendingMeta!.expectedSize,
            blockSize: _pendingMeta!.blockSize,
            fileId: fileId,
            raw: _pendingMeta!.raw);
        sess = RfdSession(bound);
        _sessions[fileId] = sess;
        logger.d('RFD: started session for fileId=$fileId $bound');
        // Drain any previously staged chunks for this fileId
        final staged = _stagingByFile.remove(fileId);
        if (staged != null) {
          for (final chunk in staged) {
            _addHeaderedChunkToSession(sess, chunk);
          }
        }
        _pendingMeta = null; // consumed
      } else {
        _stagingByFile.putIfAbsent(fileId, () => <List<int>>[]).add(auChunk);
        logger.t('RFD: staged chunk for fileId=$fileId');
        return false;
      }
    }
    sess.addAtOffset(byteOffset, payload);
    return sess.isCompleted;
  }

  void _addHeaderedChunkToSession(RfdSession session, List<int> auChunk,
      {int headerLen = 5}) {
    if (auChunk.length <= headerLen) return;
    final int offUnits = ((auChunk[2] & 0xFF) << 16) |
        ((auChunk[3] & 0xFF) << 8) |
        (auChunk[4] & 0xFF);
    final int byteOffset = offUnits << 3;
    final List<int> payload = auChunk.sublist(headerLen);
    session.addAtOffset(byteOffset, payload);
  }

  // Finish the current session and return the assembled bytes
  // Returns null if no session exists or it is not complete
  List<int>? takeIfComplete() {
    final key = _sessions.keys
        .firstWhere((k) => _sessions[k]!.isCompleted, orElse: () => -1);
    if (key == -1) return null;
    final bytes = _sessions[key]!.bytes;
    logger.d('RFD: completed file size ${bytes.length}');
    _sessions.remove(key);
    return bytes;
  }

  // Abort any current session
  void reset() {
    if (_sessions.isNotEmpty) {
      final int total =
          _sessions.values.fold(0, (acc, s) => acc + s.receivedSize);
      logger.d(
          'RFD: reset; discarding $total bytes across ${_sessions.length} sessions');
    }
    _sessions.clear();
    _stagingByFile.clear();
  }
}
