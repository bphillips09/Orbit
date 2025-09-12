// Program Guide Handler
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/crc.dart';
import 'dart:convert' as conv;
import 'dart:io' as io;

class ProgramGuideHandler extends DSIHandler {
  ProgramGuideHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.electronicProgramGuide, sxiLayer);

  static const int _maxSegmentsDefault = 8;
  _EpgPool? _currentPool; // Active pool for current epoch
  _EpgPool? _candidatePool; // Candidate pool for next epoch

  // Program slots repository
  final Map<int, _EpgProgramSlot> _slotByProgramId = <int, _EpgProgramSlot>{};
  final Map<int, List<_EpgProgramSlot>> _slotsBySeriesId =
      <int, List<_EpgProgramSlot>>{};

  _EpgProgramSlot _allocOrReplaceSlot({
    required int seriesId,
    required int programId,
    required int flags,
    required int duration,
    required Map<String, int> stringIndices,
    required List<int> topics,
  }) {
    final _EpgProgramSlot slot = _EpgProgramSlot(
      seriesId: seriesId,
      programId: programId,
      flags: flags,
      duration: duration,
      stringIndices: Map<String, int>.from(stringIndices),
      topics: List<int>.from(topics),
    );
    _slotByProgramId[programId] = slot;
    final List<_EpgProgramSlot> bySeries =
        _slotsBySeriesId.putIfAbsent(seriesId, () => <_EpgProgramSlot>[]);
    final int idx = bySeries.indexWhere((s) => s.programId == programId);
    if (idx >= 0) {
      bySeries[idx] = slot;
    } else {
      bySeries.add(slot);
    }
    return slot;
  }

  _EpgProgramSlot? _findSlotBySeriesId(int seriesId) {
    final List<_EpgProgramSlot>? lst = _slotsBySeriesId[seriesId];
    if (lst == null || lst.isEmpty) return null;
    return lst.first;
  }

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final List<int> au = unit.getHeaderAndData();
    if (au.isEmpty) return;

    // Call the main EPG AU processing function
    _sxmEpgCompleteAu(au, au.length, unit.crc);
  }

  // Main EPG AU processing function
  void _sxmEpgCompleteAu(List<int> auData, int auLength, int expectedCrc) {
    // AccessUnit.getHeaderAndData() returns header+payload (without trailing CRC)
    final BitBuffer b = BitBuffer(auData);

    final int version = b.readBits(4);

    // Validate version
    if (b.hasError || version != 1) {
      logger.e('EPG: Version verification failed ($version != 1)');
      return;
    }

    // Validate AU CRC
    if (!CRC32.check(auData, expectedCrc)) {
      logger.w(
          'EPG: CRC check failed. AU CRC: 0x${expectedCrc.toRadixString(16).toUpperCase()}');
      return;
    }

    // Read message type
    final int messageType = b.readBits(3);
    if (b.hasError) {
      logger.e('EPG: Failed to read CARID');
      return;
    }

    logger.d('EPG: AU message type=$messageType version=$version');

    // Route to appropriate message processor based on type
    switch (messageType) {
      case 0x0: // Schedule message (Grid AU)
      case 0x1: // Schedule message (Text AU)
        logger.d('EPG: MSG TYPE: Schedule Message');
        _sxmEpgProcessScheduleMessage(b, auData, auLength);
        break;
      case 0x2: // Program Announcement
        logger.d('EPG: MSG TYPE: Program Announcement Message');
        break;
      case 0x3: // Table Affinity
        logger.d('EPG: MSG TYPE: Table Affinity Message');
        _handleTableAffinity(b);
        break;
      case 0x4: // Profile Configuration
        logger.d('EPG: MSG TYPE: Profile Configuration Message');
        _handleProfileConfiguration(b);
        break;
      case 0x5: // Segment Versioning
        logger.d('EPG: MSG TYPE: Schedule Segment Versioning Message');
        _sxmEpgProcessScheduleVersioningMessage(b);
        break;
      default:
        logger.e('EPG: Unknown Message Type: $messageType');
        break;
    }
  }

  // Process schedule message
  void _sxmEpgProcessScheduleMessage(
      BitBuffer b, List<int> auData, int auLength) {
    // Read schedule message header
    final bool isText = b.readBits(1) == 1; // 1 bit: 0=GRID, 1=TEXT
    final int segmentVersion = b.readBits(5); // 5 bits: segment version
    final int epoch = b.readBits(16); // 16 bits: epoch
    final int segmentCount = b.readBits(3) + 1; // 3 bits: segment count (1-8)
    final int segmentIndex = b.readBits(3); // 3 bits: segment index (0-7)

    if (b.hasError) {
      logger.e('EPG: Failed to read Schedule AU Header');
      return;
    }

    final String auType = isText ? "TEXT" : "GRID";
    logger.d(
        'EPG: $auType AU HEADER: EPOCH: $epoch SEGVER: $segmentVersion SEGCNT: $segmentCount/$_maxSegmentsDefault SEGIDX: $segmentIndex');

    // Validate segment index is within bounds
    if (segmentIndex >= _maxSegmentsDefault) {
      logger.d(
          'EPG: Unnecessary segment $segmentIndex is ignored (>= $_maxSegmentsDefault)');
      return;
    }

    // Process schedule version to determine if we should accept this AU
    final int dayEpoch = epoch - segmentIndex;
    if (_sxmEpgProcessScheduleVersion(dayEpoch, segmentIndex, segmentVersion)) {
      // Version accepted - process the AU content
      if (isText) {
        _sxmEpgProcessTextMessage(
            dayEpoch, segmentIndex, segmentVersion, b, auData);
      } else {
        _sxmEpgProcessGridMessage(
            dayEpoch, segmentIndex, segmentVersion, b, auData);
      }

      // Readiness checks are handled inside the specific AU handlers
    } else {
      logger
          .d('EPG: Ignored segment $segmentIndex with version $segmentVersion');
    }
  }

  // Process schedule versioning message
  void _sxmEpgProcessScheduleVersioningMessage(BitBuffer b) {
    // Header: 1 reserved bit, 5-bit schedule version, 16-bit epoch
    b.skipBits(1);
    final int incomingVersion = b.readBits(5) & 0x1F;
    final int incomingEpoch = b.readBits(16) & 0xFFFF;

    if (b.hasError) {
      logger.e('EPG: Failed to read SSV Header');
      return;
    }

    final int currentEpoch = _currentPool?.epoch ?? -1;
    final int currentVersion = _currentPool?.scheduleVersion ?? 0;

    logger.d(
        'EPG: SSV: Current schedule   EPOCH:$currentEpoch VER:$currentVersion');
    logger.d(
        'EPG: SSV: Incoming schedule  EPOCH:$incomingEpoch VER:$incomingVersion');

    bool versionChanged = false;

    // Entirely changed if epoch differs or version decreased
    if (incomingEpoch != currentEpoch || incomingVersion < currentVersion) {
      logger.i('EPG: SSV: Version is entirely changed');
      versionChanged = true;
      // Prepare candidate pool for new epoch and clear AU pools
      _sxmEpgHandleAuPoolVersionChange(
          incomingEpoch, _currentPool?.totalSegments ?? _maxSegmentsDefault);
      _sxmEpgCleanAuPool();
    } else if (incomingVersion != currentVersion) {
      // Partial change: segment-specific resets follow
      versionChanged = true;
      _sxmEpgHandleAuPoolVersionChange(
          incomingEpoch, _currentPool?.totalSegments ?? _maxSegmentsDefault);

      // Number of segment version entries
      final int count = (b.readBits(3) + 1) & 0x7;
      if (b.hasError) {
        logger.e('EPG: SSV: Failed to read NOSEG');
      } else {
        final _EpgPool pool = _getOrCreatePoolForEpoch(incomingEpoch);
        final int limit = count.clamp(0, pool.totalSegments);
        for (int i = 0; i < limit; i++) {
          final int segVer = b.readBits(5) & 0x1F; // Version value
          if (b.hasError) {
            logger.e('EPG: SSV: Failed to read SEGVER');
            break;
          }
          logger.d('EPG: SSV: Segment $i  Version $segVer');
          final _EpgSegmentState? s = pool.segments[i];
          if (s != null) {
            // Reset content on segment version change
            s.resetContent();
          }
        }
      }
    } else {
      logger.d('EPG: SSV: Version is not changed');
    }

    if (versionChanged) {
      final _EpgPool pool = _getOrCreatePoolForEpoch(incomingEpoch);
      pool.scheduleVersion = incomingVersion;

      // Trigger schedule update
      _sxmEpgUpdateSchedule(true);
      _checkPoolReadiness(pool);
      _maybeSwitchPools();
    }
  }

  // Accept or reject an incoming AU based on epoch/segment version
  bool _sxmEpgProcessScheduleVersion(int epoch, int segmentIndex, int version) {
    final _EpgPool pool = _getOrCreatePoolForEpoch(epoch);
    if (segmentIndex >= pool.totalSegments) {
      pool.expandSegmentsTo(segmentIndex + 1);
    }
    final _EpgSegmentState seg = pool.segments
        .putIfAbsent(segmentIndex, () => _EpgSegmentState(segmentIndex));

    final int current = seg.version;
    // Reject strictly older segment versions for the same epoch
    if (current > 0 && version < current) {
      logger.t(
          'EPG: schedule version gate: reject seg=$segmentIndex ver=$version < current=$current');
      return false;
    }
    logger.t(
        'EPG: schedule version gate: accept seg=$segmentIndex ver=$version (current=$current)');
    return true;
  }

  void _sxmEpgProcessTextMessage(
      int dayEpoch, int segmentIndex, int segmentVersion, BitBuffer b,
      [List<int>? fullAuBytes]) {
    logger.d('EPG: Processing text message for segment $segmentIndex');
    if (fullAuBytes != null && fullAuBytes.isNotEmpty) {
      logger.t(
          'EPG: TEXT AU first bytes[32]: ${_hexSample(fullAuBytes, maxBytes: 32)}');
    }

    // Skip header fields
    final int textPreBefore = b.debugBytePos * 8 - b.debugValidBits;
    b.skipBits(16); // Skip 16 bits
    b.skipBits(24); // Skip 24 bits
    final int textPreAfter = b.debugBytePos * 8 - b.debugValidBits;
    logger.t('EPG: TEXT AU preskip 16+24 bits ($textPreBefore->$textPreAfter)');

    // Check if AU indexing header is present
    int totalAUs = 1;
    int auIndex = 0;

    if (b.readBits(1) == 1) {
      // If present bit is set
      final int width = b.readBits(4) + 1; // Width + 1
      totalAUs = b.readBits(width) + 1; // Total + 1
      auIndex = b.readBits(width); // Index
      logger
          .d('EPG: TEXT AU index: width=$width total=$totalAUs index=$auIndex');
    }

    if (b.hasError) {
      logger.e('EPG: Failed to read Text AU Header');
      return;
    }

    // Validate total AUs limit
    if (totalAUs >= 21) {
      logger.e('EPG: Max number of Text AUs exceeded ($totalAUs >= 21)');
      return;
    }

    // Prefer storing full AU bytes (version+headers+payload) so we can
    // reconstruct the compressed bitstream across AUs accurately later
    final List<int> textBytes = (fullAuBytes != null && fullAuBytes.isNotEmpty)
        ? fullAuBytes
        : (() {
            b.align();
            return b.remainingData;
          })();
    logger.t(
        'EPG: TEXT AU captured seg=$segmentIndex idx=$auIndex bytes=${textBytes.length}');
    if (textBytes.isEmpty) {
      logger.w('EPG: TEXT AU payload empty (seg=$segmentIndex idx=$auIndex)');
      return;
    }

    final _EpgPool pool = _getOrCreatePoolForEpoch(dayEpoch);
    if (segmentIndex >= pool.totalSegments) {
      pool.expandSegmentsTo(segmentIndex + 1);
    }
    final _EpgSegmentState seg = pool.segments
        .putIfAbsent(segmentIndex, () => _EpgSegmentState(segmentIndex));

    if (seg.version > 0) {
      if (segmentVersion < seg.version) {
        logger.t(
            'EPG: TEXT: ignore AU seg=$segmentIndex older ver=$segmentVersion < current=${seg.version}');
        return;
      } else if (segmentVersion > seg.version) {
        logger.i(
            'EPG: TEXT: seg $segmentIndex version bump ${seg.version} -> $segmentVersion, resetting AUs');
        seg.resetContent();
      }
    }
    seg.version = segmentVersion;

    if (totalAUs < 0x15) {
      seg.textTotal = totalAUs;
    }

    final bool added = seg.addTextAu(auIndex, textBytes);
    logger.t(
        'EPG: TEXT: saved AU seg=$segmentIndex idx=$auIndex ok=$added total=${seg.textTotal} received=${seg.textReceivedCount}');

    _checkPoolReadiness(pool);
    _maybeSwitchPools();
  }

  void _sxmEpgProcessGridMessage(
      int dayEpoch, int segmentIndex, int segmentVersion, BitBuffer b,
      [List<int>? fullAuBytes]) {
    logger.d('EPG: Processing grid message for segment $segmentIndex');

    // Skip header fields
    b.skipBits(5);
    b.skipBits(5);
    b.skipBits(4);
    b.skipBits(4);

    // Check if AU indexing header is present
    int totalAUs = 1;
    int auIndex = 0;

    if (b.readBits(1) == 1) {
      // If present bit is set
      final int width = b.readBits(4) + 1; // Width + 1
      totalAUs = b.readBits(width) + 1; // Total + 1
      auIndex = b.readBits(width); // Index
      logger
          .d('EPG: GRID AU index: width=$width total=$totalAUs index=$auIndex');
    }

    if (b.hasError) {
      logger.e('EPG: Failed to read Grid AU Header');
      return;
    }

    // Validate total AUs limit
    if (totalAUs >= 9) {
      logger.e('EPG: Max number of Grid AUs exceeded ($totalAUs >= 9)');
      return;
    }

    // Prefer storing full AU bytes (header+payload)
    List<int> gridBytes;
    if (fullAuBytes != null && fullAuBytes.isNotEmpty) {
      gridBytes = fullAuBytes;
    } else {
      b.align();
      final List<int> rem = b.remainingData;
      if (rem.isEmpty) {
        logger.w('EPG: GRID AU payload empty (seg=$segmentIndex idx=$auIndex)');
        return;
      }
      gridBytes = rem;
    }

    final _EpgPool pool = _getOrCreatePoolForEpoch(dayEpoch);
    if (segmentIndex >= pool.totalSegments) {
      pool.expandSegmentsTo(segmentIndex + 1);
    }
    final _EpgSegmentState seg = pool.segments
        .putIfAbsent(segmentIndex, () => _EpgSegmentState(segmentIndex));

    if (seg.version > 0) {
      if (segmentVersion < seg.version) {
        logger.t(
            'EPG: GRID: ignore AU seg=$segmentIndex older ver=$segmentVersion < current=${seg.version}');
        return;
      } else if (segmentVersion > seg.version) {
        logger.i(
            'EPG: GRID: seg $segmentIndex version bump ${seg.version} -> $segmentVersion, resetting AUs');
        seg.resetContent();
      }
    }
    seg.version = segmentVersion;

    if (totalAUs < 9) {
      seg.gridTotal = totalAUs;
    }

    final bool added = seg.addGridAu(auIndex, gridBytes);
    logger.t(
        'EPG: GRID: saved AU seg=$segmentIndex idx=$auIndex ok=$added total=${seg.gridTotal} received=${seg.gridReceivedCount}');

    _checkPoolReadiness(pool);
    _maybeSwitchPools();
  }

  void _sxmEpgHandleAuPoolVersionChange(int epoch, int totalSegments) {
    logger.d(
        'EPG: Handling AU pool version change -> epoch=$epoch segments=$totalSegments');
    if (_currentPool != null && _currentPool!.epoch == epoch) {
      if (totalSegments > _currentPool!.totalSegments) {
        _currentPool!.expandSegmentsTo(totalSegments);
      } else if (totalSegments < _currentPool!.totalSegments) {
        _currentPool!.shrinkSegmentsTo(totalSegments);
      }
      return;
    }
    _candidatePool = _EpgPool(epoch: epoch, totalSegments: totalSegments);
    logger.i('EPG: Candidate pool prepared for epoch=$epoch');
  }

  void _sxmEpgCleanAuPool() {
    logger.d('EPG: Cleaning AU pools');
    final _EpgPool? c = _currentPool;
    final _EpgPool? n = _candidatePool;
    if (c != null) {
      c.segments.forEach((_, s) => s.resetContent());
      c.extracted.clear();
      c.stringTables.clear();
    }
    if (n != null) {
      n.segments.forEach((_, s) => s.resetContent());
      n.extracted.clear();
      n.stringTables.clear();
    }
  }

  void _sxmEpgUpdateSchedule(bool immediate) {
    final _EpgPool? c = _currentPool;
    if (c != null) {
      _checkPoolReadiness(c);
    }
    final _EpgPool? n = _candidatePool;
    if (n != null) {
      _checkPoolReadiness(n);
    }
  }

  // Helper to format a short hex preview of a byte list
  String _hexSample(List<int> data, {int maxBytes = 32}) {
    final int n = data.length < maxBytes ? data.length : maxBytes;
    return data
        .take(n)
        .map((v) => (v & 0xFF).toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }

  // Log a base64 dump in manageable chunks
  void _logBase64Dump(String prefix, List<int> data, {int chunkChars = 512}) {
    final String b64 = conv.base64.encode(data);
    logger
        .t('$prefix BASE64 BEGIN lenBytes=${data.length} lenB64=${b64.length}');
    for (int i = 0; i < b64.length; i += chunkChars) {
      final int end =
          (i + chunkChars < b64.length) ? i + chunkChars : b64.length;
      logger.t('$prefix ${i.toString().padLeft(6)}:${b64.substring(i, end)}');
    }
    logger.t('$prefix BASE64 END');
  }

  Map<String, int> _extractStringIndices(BitBuffer b,
      {int stringIndexWidth = 8, int? segmentIndex}) {
    final Map<String, int> indices = <String, int>{};

    // Primary title index
    final int w = stringIndexWidth.clamp(1, 16);
    final int titleIdx = b.readBits(w) & ((1 << w) - 1);
    // Encode segment table id (upper 8 bits)
    final int segId = (segmentIndex ?? 0) & 0xFF;
    indices['title'] = titleIdx | (segId << 24);

    // Optional subtitle
    if (b.readBits(1) == 1) {
      final int subtitleIdx = b.readBits(w) & ((1 << w) - 1);
      indices['subtitle'] = subtitleIdx | (segId << 24);
    }

    // Optional description
    if (b.readBits(1) == 1) {
      final int descIdx = b.readBits(w) & ((1 << w) - 1);
      indices['description'] = descIdx | (segId << 24);
    }

    // Optional extended description
    if (b.readBits(1) == 1) {
      final int extDescIdx = b.readBits(w) & ((1 << w) - 1);
      indices['extendedDescription'] = extDescIdx | (segId << 24);
    }

    // Optional category (16-bit field)
    if (b.readBits(1) == 1) {
      final int categoryIdx = b.readBits(16) & 0xFFFF;
      indices['category'] = categoryIdx | (segId << 24);
    }

    return indices;
  }

  void _handleTableAffinity(BitBuffer b) {
    logger.d('EPG: Table Affinity message');
  }

  void _handleProfileConfiguration(BitBuffer b) {
    logger.d('EPG: Profile Configuration message');
  }

  _EpgPool _getOrCreatePoolForEpoch(int epoch) {
    if (_currentPool == null) {
      _currentPool = _EpgPool(epoch: epoch, totalSegments: _maxSegmentsDefault);
      logger.i('EPG: Created current pool for epoch=$epoch');
      return _currentPool!;
    }
    if (_currentPool!.epoch == epoch) {
      return _currentPool!;
    }
    if (_candidatePool != null && _candidatePool!.epoch == epoch) {
      return _candidatePool!;
    }
    // Create/replace candidate for new epoch
    _candidatePool = _EpgPool(epoch: epoch, totalSegments: _maxSegmentsDefault);
    logger.i('EPG: Created candidate pool for epoch=$epoch');
    return _candidatePool!;
  }

  // Program retrieval
  EpgGetProgramResult getProgram({
    required int dayIndex,
    required int sid,
    required int timeSeconds,
    bool useCandidate = false,
  }) {
    final _EpgPool? pool = useCandidate ? _candidatePool : _currentPool;
    if (pool == null) {
      return const EpgGetProgramResult(status: EpgGetProgramStatus.notStarted);
    }
    if (pool.scheduleExtractionInProgress) {
      return const EpgGetProgramResult(
          status: EpgGetProgramStatus.extractionInProgress);
    }
    if (dayIndex < 0 || dayIndex >= pool.totalSegments) {
      return const EpgGetProgramResult(status: EpgGetProgramStatus.invalidDay);
    }
    if (sid <= 0 || sid >= 0x180) {
      return const EpgGetProgramResult(status: EpgGetProgramStatus.invalidSid);
    }
    if (timeSeconds < 0 || timeSeconds >= 86400) {
      return const EpgGetProgramResult(status: EpgGetProgramStatus.invalidTime);
    }

    final _EpgDaySchedule? day = pool.extracted[dayIndex];
    if (day == null || day.events.isEmpty) {
      return const EpgGetProgramResult(status: EpgGetProgramStatus.notFound);
    }

    // Find program by SID and time window [start, start+duration)
    for (final _EpgProgramEvent ev in day.events) {
      if (ev.sid != sid) continue;
      final int start = ev.startSeconds;
      final int end = start + ev.durationSeconds;
      if (timeSeconds >= start && timeSeconds < end) {
        final EpgProgramEventView view = EpgProgramEventView(
          sid: ev.sid,
          startSeconds: ev.startSeconds,
          durationSeconds: ev.durationSeconds,
          flags: ev.flags,
          decodedFlags: _decodeFlags(ev.flags),
          topics: List<int>.from(ev.topics),
          title: ev.title ??
              _resolveString(pool, dayIndex, ev.stringIndices, 'title'),
          subtitle: ev.subtitle ??
              _resolveString(pool, dayIndex, ev.stringIndices, 'subtitle'),
        );
        return EpgGetProgramResult(
            status: EpgGetProgramStatus.ok, program: view);
      }
    }

    return const EpgGetProgramResult(status: EpgGetProgramStatus.notFound);
  }

  String? _resolveString(
      _EpgPool pool, int defaultSegIdx, Map<String, int>? indices, String key) {
    if (indices == null) return null;
    final int? encodedIdx = indices[key];
    if (encodedIdx == null) return null;

    final int actualIdx = encodedIdx & 0xFFFFFF;
    final int segTableId = (encodedIdx >> 24) & 0xFF;

    // Prefer table by segTableId if present, otherwise fall back to segment's table
    List<String>? table = pool.stringTablesById[segTableId] ??
        pool.stringTables[segTableId] ??
        pool.stringTables[defaultSegIdx];

    if (table == null || table.isEmpty) {
      logger.t(
          'EPG: String resolve failed: key=$key no table for segTableId=$segTableId defaultSeg=$defaultSegIdx');
      return null;
    }

    if (actualIdx < 0 || actualIdx >= table.length) {
      logger.t(
          'EPG: String resolve failed: key=$key encodedIdx=0x${encodedIdx.toRadixString(16)} actualIdx=$actualIdx segTableId=$segTableId tableLen=${table.length}');
      return null;
    }

    final String resolved = table[actualIdx];
    logger.t(
        'EPG: String resolved: key=$key segTableId=$segTableId idx=$actualIdx -> "$resolved" (tableLen=${table.length})');
    return resolved;
  }

  void _maybeSwitchPools() {
    if (_candidatePool == null) return;
    if (_currentPool == null) {
      _currentPool = _candidatePool;
      _candidatePool = null;
      logger.i('EPG: Switched to candidate pool (no current)');
      return;
    }

    final int currReady = _currentPool!.countAssembledSegments();
    final int candReady = _candidatePool!.countAssembledSegments();

    // Require candidate to have at least 2 assembled segments
    // and be at least as good as current
    if (candReady >= 2 && candReady >= currReady) {
      final int from = _currentPool!.epoch;
      final int to = _candidatePool!.epoch;
      _currentPool = _candidatePool;
      _candidatePool = null;
      logger.i(
          'EPG: Switched pools epoch $from -> $to (ready: $currReady->$candReady)');
    }
  }

  void _checkPoolReadiness(_EpgPool pool) {
    for (int i = 0; i < pool.totalSegments; i++) {
      final _EpgSegmentState? s = pool.segments[i];
      if (s == null) continue;
      final bool ready = s.gridReceivedCount > 0 &&
          s.textReceivedCount > 0 &&
          (s.gridTotal == 0 || s.gridReceivedCount == s.gridTotal) &&
          (s.textTotal == 0 || s.textReceivedCount == s.textTotal);
      if (!ready) {
        logger.t(
            'EPG: [epoch=${pool.epoch}] SEGMENT $i INCOMPLETE. GRID ${s.gridReceivedCount}/${s.gridTotal} '
            'TEXT ${s.textReceivedCount}/${s.textTotal}');
      } else {
        logger.t('EPG: [epoch=${pool.epoch}] SEGMENT $i AUs ASSEMBLED');
      }
    }

    // Only trigger extraction when we have a contiguous prefix of assembled segments
    int contiguous = 0;
    for (int i = 0; i < pool.totalSegments; i++) {
      final _EpgSegmentState? s = pool.segments[i];
      if (s == null) break;
      final bool ready = s.gridReceivedCount > 0 &&
          s.textReceivedCount > 0 &&
          (s.gridTotal == 0 || s.gridReceivedCount == s.gridTotal) &&
          (s.textTotal == 0 || s.textReceivedCount == s.textTotal);
      if (ready) {
        contiguous++;
      } else {
        break;
      }
    }

    if (contiguous > 0 && !pool.scheduleExtractionInProgress) {
      pool.scheduleExtractionInProgress = true;
      logger.i(
          'EPG: [epoch=${pool.epoch}] Schedule extraction starting (contiguous=$contiguous/${pool.totalSegments})');
      try {
        // Extract up to the highest contiguous assembled index
        _updateSchedule(pool: pool, force: true);
      } finally {
        pool.scheduleExtractionInProgress = false;
      }
    }
  }

  // Expose a read-only snapshot for UI consumption
  List<EpgSegmentView> getScheduleSnapshot() {
    final List<EpgSegmentView> out = <EpgSegmentView>[];
    final _EpgPool? pool = _currentPool;
    if (pool == null) return out;
    for (int segIdx = 0; segIdx < pool.totalSegments; segIdx++) {
      final _EpgSegmentState? seg = pool.segments[segIdx];
      if (seg == null) continue;
      final _EpgDaySchedule? day = seg.extracted;
      final int stringCount = pool.stringTables[segIdx]?.length ?? 0;
      final List<EpgProgramEventView> items = <EpgProgramEventView>[];
      if (day != null) {
        for (final _EpgProgramEvent ev in day.events) {
          items.add(EpgProgramEventView(
            sid: ev.sid,
            startSeconds: ev.startSeconds,
            durationSeconds: ev.durationSeconds,
            flags: ev.flags,
            decodedFlags: _decodeFlags(ev.flags),
            topics: List<int>.from(ev.topics),
            title: ev.title,
            subtitle: ev.subtitle,
          ));
        }
      }
      final List<int> gridIdx = seg._gridAus.keys.toList()..sort();
      final List<int> textIdx = seg._textAus.keys.toList()..sort();
      final int gridBytes = seg._gridAus.values.fold(0, (a, b) => a + b.length);
      final int textBytes = seg._textAus.values.fold(0, (a, b) => a + b.length);
      out.add(EpgSegmentView(
        segmentIndex: segIdx,
        events: items,
        stringTable: pool.stringTables[segIdx],
        stringTableSize: stringCount,
        gridReceived: seg.gridReceivedCount,
        gridTotal: seg.gridTotal,
        textReceived: seg.textReceivedCount,
        textTotal: seg.textTotal,
        gridIndices: gridIdx,
        textIndices: textIdx,
        gridBytes: gridBytes,
        textBytes: textBytes,
      ));
    }
    return out;
  }

  // Expose snapshots for all pools (current and candidate) for UI
  List<EpgPoolView> getAllPoolsSnapshot() {
    final List<EpgPoolView> out = <EpgPoolView>[];
    if (_currentPool != null) {
      out.add(_snapshotPool(_currentPool!, isCurrent: true));
    }
    if (_candidatePool != null) {
      out.add(_snapshotPool(_candidatePool!, isCurrent: false));
    }
    return out;
  }

  EpgPoolView _snapshotPool(_EpgPool pool, {required bool isCurrent}) {
    final List<EpgSegmentView> segments = <EpgSegmentView>[];
    for (int segIdx = 0; segIdx < pool.totalSegments; segIdx++) {
      final _EpgSegmentState? seg = pool.segments[segIdx];
      if (seg == null) continue;
      final _EpgDaySchedule? day = seg.extracted;
      final int stringCount = pool.stringTables[segIdx]?.length ?? 0;
      final List<EpgProgramEventView> items = <EpgProgramEventView>[];
      if (day != null) {
        for (final _EpgProgramEvent ev in day.events) {
          items.add(EpgProgramEventView(
            sid: ev.sid,
            startSeconds: ev.startSeconds,
            durationSeconds: ev.durationSeconds,
            flags: ev.flags,
            decodedFlags: _decodeFlags(ev.flags),
            topics: List<int>.from(ev.topics),
            title: ev.title,
            subtitle: ev.subtitle,
          ));
        }
      }
      final List<int> gridIdx = seg._gridAus.keys.toList()..sort();
      final List<int> textIdx = seg._textAus.keys.toList()..sort();
      final int gridBytes = seg._gridAus.values.fold(0, (a, b) => a + b.length);
      final int textBytes = seg._textAus.values.fold(0, (a, b) => a + b.length);
      segments.add(EpgSegmentView(
        segmentIndex: segIdx,
        events: items,
        stringTable: pool.stringTables[segIdx],
        stringTableSize: stringCount,
        gridReceived: seg.gridReceivedCount,
        gridTotal: seg.gridTotal,
        textReceived: seg.textReceivedCount,
        textTotal: seg.textTotal,
        gridIndices: gridIdx,
        textIndices: textIdx,
        gridBytes: gridBytes,
        textBytes: textBytes,
      ));
    }
    return EpgPoolView(
        epoch: pool.epoch, isCurrent: isCurrent, segments: segments);
  }

  // Schedule extraction pipeline
  void _updateSchedule({required _EpgPool pool, required bool force}) {
    // Choose the last index of the contiguous assembled prefix
    int assembled = -1;
    for (int i = 0; i < pool.totalSegments; i++) {
      final _EpgSegmentState? s = pool.segments[i];
      if (s == null || !s.isAssembled) break;
      assembled = i;
    }
    if (assembled < 0) return;

    final int result = _updateScheduleSegment(pool, assembled, force ? 1 : 0);
    if (result != 0 && result != 8) {
      // On decode error, reset pool and keep going next time
      logger.w(
          'EPG: updateSchedule: decode failed (code=$result), will reset pool epoch=${pool.epoch}');
      pool.segments.forEach((_, s) => s.resetContent());
    }
  }

  int _updateScheduleSegment(_EpgPool pool, int maxSegmentInclusive, int arg) {
    // Clamp to available segments
    int lastIdx = maxSegmentInclusive;
    if (lastIdx >= pool.totalSegments) lastIdx = pool.totalSegments - 1;

    for (int segIdx = 0; segIdx <= lastIdx; segIdx++) {
      final _EpgSegmentState? state = pool.segments[segIdx];
      if (state == null || !state.isAssembled) {
        continue;
      }
      final int r = _extractDaySchedule(pool, segIdx);
      if (r != 0) {
        logger
            .w('EPG: Failed to extract schedule for segment $segIdx (code=$r)');
        return r;
      }

      logger.i('EPG: SEGMENT $segIdx EXTRACTED');
      // Replace schedule segment (publish into extracted map)
      final _EpgSegmentState? seg = pool.segments[segIdx];
      if (seg == null) continue;
      final _EpgDaySchedule? day = seg.extracted;
      if (day != null) {
        pool.extracted[segIdx] = day;
      }

      // If arg is non-zero, extract only the first, otherwise continue to next
      if (arg != 0) {
        break;
      }
    }
    return 0;
  }

  int _extractDaySchedule(_EpgPool pool, int segIdx) {
    final _EpgSegmentState? seg = pool.segments[segIdx];
    if (seg == null) return 8; // Not ready
    if (!seg.isAssembled) return 8;

    // 1) Build/update string table for this segment using aggregated raw-deflate
    _buildStringTableForSegment(pool, segIdx);
    final int strCount = pool.stringTables[segIdx]?.length ?? 0;
    logger.t(
        'EPG: seg=$segIdx stringTable status: present=${strCount > 0} len=$strCount');

    // 2) Extract GRID data by processing each AU individually
    final _EpgDaySchedule day = _EpgDaySchedule(segmentIndex: segIdx);
    final List<int> gridIndices = seg._gridAus.keys.toList()..sort();

    if (gridIndices.isEmpty) return 2;

    // Process each GRID AU separately
    for (final int auIdx in gridIndices) {
      final List<int>? gridAu = seg._gridAus[auIdx];
      if (gridAu == null || gridAu.isEmpty) continue;

      logger.t(
          'EPG: seg=$segIdx processing GRID AU idx=$auIdx bytes=${gridAu.length}');
      logger.t(
          'EPG: seg=$segIdx AU[$auIdx] first bytes[32]: ${_hexSample(gridAu, maxBytes: 32)}');

      final int result = _extractGridAu(gridAu, segIdx, day, seg, pool);
      if (result != 0) {
        logger
            .w('EPG: seg=$segIdx AU[$auIdx] extraction failed (code=$result)');
        return result;
      }
    }

    seg.extracted = day;
    logger.i('EPG: seg=$segIdx extracted ${day.events.length} events total');
    return 0;
  }

  // Extract one GRID AU
  int _extractGridAu(List<int> gridAu, int segIdx, _EpgDaySchedule day,
      _EpgSegmentState seg, _EpgPool pool) {
    final BitBuffer b = BitBuffer(gridAu);
    // Saved AU bytes begin at the start of the message payload (without the
    // 4-byte outer header) and still include the schedule header fields
    final int bitPosBeforePreskip = b.debugBytePos * 8 - b.debugValidBits;
    b.skipBits(4);
    b.skipBits(3);
    b.skipBits(1);
    b.skipBits(5);
    b.skipBits(16);
    b.skipBits(3);
    b.skipBits(3);
    final int bitPosAfterPreskip = b.debugBytePos * 8 - b.debugValidBits;
    logger.t(
        'EPG: seg=$segIdx AU preskip 4+3+1+5+16+3+3 bits ($bitPosBeforePreskip->$bitPosAfterPreskip)');

    // Read header widths (store globally for this segment)
    final int sidWidth = b.readBits(5) + 1;
    final int progCountWidth = b.readBits(5) + 1;
    final int durWidth = b.readBits(4) + 1;
    final int topicWidth = b.readBits(4) + 1;
    seg.sidWidth = sidWidth;
    seg.progCountWidth = progCountWidth;
    seg.durationWidth = durWidth;
    seg.topicWidth = topicWidth;

    logger.d(
        'EPG: AU header widths: sid=$sidWidth progCount=$progCountWidth dur=$durWidth topic=$topicWidth (bitPos=${b.debugBytePos * 8 - b.debugValidBits})');

    if (b.hasError) return 2;

    final int optBlockPresent = b.readBits(1);
    logger.t(
        'EPG: AU optional block present=$optBlockPresent (bitPos=${b.debugBytePos * 8 - b.debugValidBits})');
    if (optBlockPresent == 1) {
      final int skipLenARaw = b.readBits(4);
      final int skipALenBits = (skipLenARaw + 1);
      logger.t(
          'EPG: AU optional block A lenRaw=$skipLenARaw -> $skipALenBits bits (bitPos=${b.debugBytePos * 8 - b.debugValidBits})');
      b.skipBits(skipALenBits);

      final int skipLenBRaw = b.readBits(4);
      final int skipBLenBits = (skipLenBRaw + 1);
      logger.t(
          'EPG: AU optional block B lenRaw=$skipLenBRaw -> $skipBLenBits bits (bitPos=${b.debugBytePos * 8 - b.debugValidBits})');
      b.skipBits(skipBLenBits);

      logger.t(
          'EPG: AU after skipping optional blocks (bitPos=${b.debugBytePos * 8 - b.debugValidBits})');
    }

    if (b.hasError) return 2;

    // Iterate SIDs using SINC coding (2-bit ops)
    int currentSid = 0;
    while (true) {
      final int bitPosBefore = b.debugBytePos * 8 - b.debugValidBits;
      final int code =
          _extractSid(b, sidAbsWidth: 10, refSid: (v) => currentSid = v);
      if (code == 0xFFFFFFFF) {
        logger.e('EPG: AU SINC extraction failed');
        return 2; // Error
      }
      if (code == 0) {
        logger.t('EPG: AU SINC returned END OF LIST');
        break; // End of list
      }
      if (code == 1) {
        final int oldSid = currentSid;
        currentSid += 1;
        logger.t('EPG: AU SINC: Inc 1 SID: $oldSid + 1 = $currentSid');
      }
      if (code == 2) {
        final int oldSid = currentSid;
        currentSid += 2;
        logger.t('EPG: AU SINC: Inc 2 SID: $oldSid + 2 = $currentSid');
      }
      if (code == 3) {
        // Absolute SID already assigned via refSid callback (used for last event)
      }
      final int bitPosAfter = b.debugBytePos * 8 - b.debugValidBits;
      logger.t(
          'EPG: AU SINC op=$code -> SID=$currentSid (bits $bitPosBefore->$bitPosAfter)');

      if (currentSid >= 0x180) {
        logger.w(
            'EPG: AU parsed out-of-range SID $currentSid (>= 0x180). Check bit alignment.');
      }

      // Number of program events for this SID, fixed 6-bit width (+1)
      final int numPrograms = (b.readBits(6) + 1);
      final int bitPosAfterCount = b.debugBytePos * 8 - b.debugValidBits;
      if (b.hasError) return 2;

      logger.d(
          'EPG: AU SID $currentSid has $numPrograms programs (bitPos=$bitPosAfterCount)');

      int accumulatedSeconds = 0;
      for (int i = 0; i < numPrograms; i++) {
        final _EpgProgramEvent ev = _extractProgramEvent(
          b,
          sid: currentSid,
          seg: seg,
        );
        if (!ev.isValid) return 2; // Read error

        if (ev.advanceOnly) {
          // DURATION-only event, advance the time cursor without emitting (only affects time)
          accumulatedSeconds += ev.durationSeconds;
          continue;
        }

        ev.startSeconds = accumulatedSeconds;
        accumulatedSeconds += ev.durationSeconds;
        logger.t(
            'EPG: AU SID=$currentSid ev#${i + 1} start=${ev.startSeconds}s dur=${ev.durationSeconds}s flags=0x${ev.flags.toRadixString(16)} topics=${ev.topics}');

        // Resolve strings if indices exist and a string table is present
        if (ev.stringIndices != null) {
          logger.t(
              'EPG: Resolving strings for SID=$currentSid using composite indices: seg=$segIdx indices=${ev.stringIndices}');
          final String? title =
              _resolveString(pool, segIdx, ev.stringIndices, 'title');
          final String? subtitle =
              _resolveString(pool, segIdx, ev.stringIndices, 'subtitle');
          if (title != null) {
            ev.title = title;
            logger.t('EPG: Resolved title = "${ev.title}"');
          }
          if (subtitle != null) {
            ev.subtitle = subtitle;
            logger.t('EPG: Resolved subtitle = "${ev.subtitle}"');
          }
        } else {
          logger.t('EPG: No string resolution: indices=false');
        }

        if (currentSid < 0x180) {
          day.addEvent(ev);
        } else {
          logger.t('EPG: Skipping event for out-of-range SID=$currentSid');
        }

        // Emit any additional instances for this program (same SID, same dur/flags/topics)
        if (ev.additionalStarts.isNotEmpty) {
          for (final int start in ev.additionalStarts) {
            if (start < 0 || start >= 86400) continue;
            final _EpgProgramEvent copy = _EpgProgramEvent(
              sid: ev.sid,
              flags: ev.flags,
              durationSeconds: ev.durationSeconds,
              topics: List<int>.from(ev.topics),
              stringIndices: ev.stringIndices == null
                  ? null
                  : Map<String, int>.from(ev.stringIndices!),
            );
            copy.startSeconds = start;
            // Resolve strings for copy using composite index
            if (copy.stringIndices != null) {
              final String? t2 =
                  _resolveString(pool, segIdx, copy.stringIndices, 'title');
              final String? s2 =
                  _resolveString(pool, segIdx, copy.stringIndices, 'subtitle');
              if (t2 != null) copy.title = t2;
              if (s2 != null) copy.subtitle = s2;
            }
            if (copy.sid < 0x180) {
              day.addEvent(copy);
            }
          }
        }
      }
    }

    return 0;
  }

  List<String> _splitZeroTerminatedUtf8(List<int> raw) {
    final List<String> out = <String>[];
    final List<int> cur = <int>[];
    for (final int byte in raw) {
      if (byte == 0) {
        out.add(conv.utf8.decode(cur, allowMalformed: true));
        cur.clear();
      } else {
        cur.add(byte);
      }
    }
    if (cur.isNotEmpty) {
      out.add(conv.utf8.decode(cur, allowMalformed: true));
    }
    return out;
  }

  int _extractSid(BitBuffer b,
      {required int sidAbsWidth, required void Function(int) refSid}) {
    final int bitPosBeforeSinc = b.debugBytePos * 8 - b.debugValidBits;
    final int sinc = b.readBits(2);
    final int bitPosAfterSinc = b.debugBytePos * 8 - b.debugValidBits;
    if (b.hasError) {
      logger.e('EPG: Failed to read SINC');
      return 0xFFFFFFFF;
    }
    if (sinc > 3) {
      logger.e('EPG: Invalid SINC value: $sinc');
      return 0xFFFFFFFF;
    }

    switch (sinc) {
      case 0: // END OF LIST
        logger.t(
            'EPG: SINC: END OF LIST (bits $bitPosBeforeSinc->$bitPosAfterSinc)');
        return sinc;
      case 1: // INC +1
        // We can't directly access the reference, so we return the SINC code
        // and let the caller handle the increment
        logger.t(
            'EPG: SINC: Inc 1 SID (bits $bitPosBeforeSinc->$bitPosAfterSinc)');
        return sinc;
      case 2: // INC +2
        // We can't directly access the reference, so we return the SINC code
        // and let the caller handle the increment
        logger.t(
            'EPG: SINC: Inc 2 SID (bits $bitPosBeforeSinc->$bitPosAfterSinc)');
        return sinc;
      case 3: // ABSOLUTE (uses sidAbsWidth from AU header)
        final int bitPosBeforeAbs = b.debugBytePos * 8 - b.debugValidBits;
        final int sidVal = b.readBits(sidAbsWidth) & ((1 << sidAbsWidth) - 1);
        final int bitPosAfterAbs = b.debugBytePos * 8 - b.debugValidBits;
        if (b.hasError) {
          logger.e('EPG: Failed to read SID');
          return 0xFFFFFFFF;
        }
        logger.t(
            'EPG: SINC: Absolute SID: $sidVal width=$sidAbsWidth (bits $bitPosBeforeAbs->$bitPosAfterAbs)');
        refSid(sidVal);
        return sinc;
    }
    return 0xFFFFFFFF;
  }

  _EpgProgramEvent _extractProgramEvent(
    BitBuffer b, {
    required int sid,
    required _EpgSegmentState seg,
  }) {
    if (b.hasError) return _EpgProgramEvent.empty();

    // First 2 bits inside each program event specify the type (PEM type)
    final int pemType = b.readBits(2) & 0x3;
    if (b.hasError) return _EpgProgramEvent.empty();
    logger.t('EPG: Program event PEM type=$pemType');

    int flags = 0xFFC0; // Default when not present
    int durationSeconds = 0;
    List<int> topics = const <int>[];
    final int topicWidth = (seg.topicWidth ?? 5).clamp(1, 16);

    switch (pemType) {
      case 0: // FULL
        // Series ID presence then value
        int seriesId = 0xFFFFFFFF;
        if ((b.readBits(1) & 1) == 1) {
          final int sidW = (seg.sidWidth ?? 10).clamp(1, 16);
          seriesId = b.readBits(sidW) & ((1 << sidW) - 1);
        }
        if (b.hasError) return _EpgProgramEvent.empty();

        // Program ID
        final int progW = (seg.progCountWidth ?? 6).clamp(1, 16);
        final int programId = b.readBits(progW) & ((1 << progW) - 1);
        if (b.hasError) return _EpgProgramEvent.empty();

        flags = _extractProgramFlags(b);
        if (flags == -1) return _EpgProgramEvent.empty();
        if (flags == 0xFFC0) flags = 0;
        durationSeconds = _extractDuration(b, 0, true); // forced
        if (durationSeconds == -1) return _EpgProgramEvent.empty();
        topics = _extractTopics(b, topicWidth);
        // String indices sized per segment durationWidth, encoded with segment index
        final int strW = (seg.durationWidth ?? 8).clamp(1, 16);
        final Map<String, int> indices = _extractStringIndices(b,
            stringIndexWidth: strW, segmentIndex: seg.index);
        logger.t('EPG: Program FULL: strings=$indices');
        // Additional start times (optional) and optional day-mask
        final List<int> additionalStarts = _extractAdditionalTimes(b);
        int additionalDaysMask = 0;
        if (additionalStarts.isNotEmpty) {
          if (b.readBits(1) == 1) {
            additionalDaysMask = b.readBits(7) & 0x7F;
          }
          logger.t(
              'EPG: Program FULL: additionalTimes=${additionalStarts.length} mask=0x${additionalDaysMask.toRadixString(16)}');
        }
        // Optional extension block
        if (b.readBits(1) == 1) {
          final int extLen = (b.readBits(8) + 1) << 3;
          b.skipBits(extLen);
        }

        // Persist a slot to support subsequent MODIFY/ADD
        _allocOrReplaceSlot(
          seriesId: seriesId,
          programId: programId,
          flags: flags,
          duration: durationSeconds,
          stringIndices: indices,
          topics: topics,
        );
        return _EpgProgramEvent(
          sid: sid,
          flags: flags,
          durationSeconds: durationSeconds,
          topics: topics,
          stringIndices: indices,
          additionalStarts: additionalStarts,
          additionalDaysMask: additionalDaysMask,
        );
      case 1: // MODIFY
        // Program ID to modify
        final int progW1 = (seg.progCountWidth ?? 6).clamp(1, 16);
        final int programId1 = b.readBits(progW1) & ((1 << progW1) - 1);
        if (b.hasError) return _EpgProgramEvent.empty();

        flags = _extractProgramFlags(b);
        if (flags == -1) return _EpgProgramEvent.empty();
        durationSeconds = _extractDuration(b, 0, false); // Optional
        if (durationSeconds == -1) return _EpgProgramEvent.empty();
        topics = _extractTopics(b, topicWidth);
        // Additional start times (optional) and optional day-mask
        final List<int> additionalStarts = _extractAdditionalTimes(b);
        int additionalDaysMask = 0;
        if (additionalStarts.isNotEmpty) {
          if (b.readBits(1) == 1) {
            additionalDaysMask = b.readBits(7) & 0x7F;
          }
          logger.t(
              'EPG: Program MODIFY: additionalTimes=${additionalStarts.length} mask=0x${additionalDaysMask.toRadixString(16)}');
        }
        if (b.readBits(1) == 1) {
          final int extLen = (b.readBits(8) + 1) << 3;
          b.skipBits(extLen);
        }

        // Merge fields with existing slot if any
        final _EpgProgramSlot? base = _slotByProgramId[programId1];
        final int outFlags = (flags == 0xFFC0) ? (base?.flags ?? 0) : flags;
        final int outDur =
            (durationSeconds > 0) ? durationSeconds : (base?.duration ?? 0);
        final List<int> outTopics =
            topics.isNotEmpty ? topics : (base?.topics ?? const <int>[]);
        return _EpgProgramEvent(
          sid: sid,
          flags: outFlags,
          durationSeconds: outDur,
          topics: outTopics,
          stringIndices: base?.stringIndices,
          additionalStarts: additionalStarts,
          additionalDaysMask: additionalDaysMask,
        );
      case 2: // ADD
        // Series then new program ID
        final int sidW2 = (seg.sidWidth ?? 10).clamp(1, 16);
        final int seriesId2 = b.readBits(sidW2) & ((1 << sidW2) - 1);
        final int progW2 = (seg.progCountWidth ?? 6).clamp(1, 16);
        final int programId2 = b.readBits(progW2) & ((1 << progW2) - 1);
        if (b.hasError) return _EpgProgramEvent.empty();

        flags = _extractProgramFlags(b);
        if (flags == -1) return _EpgProgramEvent.empty();
        durationSeconds = _extractDuration(b, 0, false); // Optional
        if (durationSeconds == -1) return _EpgProgramEvent.empty();
        topics = _extractTopics(b, topicWidth);
        // Additional start times (optional) and optional day-mask
        final List<int> additionalStarts = _extractAdditionalTimes(b);
        int additionalDaysMask = 0;
        if (additionalStarts.isNotEmpty) {
          if (b.readBits(1) == 1) {
            additionalDaysMask = b.readBits(7) & 0x7F;
          }
          logger.t(
              'EPG: Program ADD: additionalTimes=${additionalStarts.length} mask=0x${additionalDaysMask.toRadixString(16)}');
        }
        if (b.readBits(1) == 1) {
          final int extLen = (b.readBits(8) + 1) << 3;
          b.skipBits(extLen);
        }

        // Seed from existing slot by series, if any
        final _EpgProgramSlot? base2 = _findSlotBySeriesId(seriesId2);
        final int outFlags2 = (flags == 0xFFC0) ? (base2?.flags ?? 0) : flags;
        final int outDur2 =
            (durationSeconds > 0) ? durationSeconds : (base2?.duration ?? 0);
        final List<int> outTopics2 =
            topics.isNotEmpty ? topics : (base2?.topics ?? const <int>[]);
        _allocOrReplaceSlot(
          seriesId: seriesId2,
          programId: programId2,
          flags: outFlags2,
          duration: outDur2,
          stringIndices: Map<String, int>.from(
              base2?.stringIndices ?? const <String, int>{}),
          topics: outTopics2,
        );
        final _EpgProgramSlot? newSlot = _slotByProgramId[programId2];
        return _EpgProgramEvent(
          sid: sid,
          flags: outFlags2,
          durationSeconds: outDur2,
          topics: outTopics2,
          stringIndices: newSlot?.stringIndices ?? base2?.stringIndices,
          additionalStarts: additionalStarts,
          additionalDaysMask: additionalDaysMask,
        );
      case 3: // DURATION only
        // No flags/topics here; only duration to advance time
        durationSeconds = _extractDuration(b, 0, true);
        if (durationSeconds == -1) return _EpgProgramEvent.empty();
        topics = const <int>[];
        flags = 0;
        return _EpgProgramEvent(
          sid: sid,
          flags: flags,
          durationSeconds: durationSeconds,
          topics: topics,
          advanceOnly: true,
        );
      default:
        return _EpgProgramEvent.empty();
    }
  }

  // Extract program flags
  int _extractProgramFlags(BitBuffer b) {
    int flags = 0;
    bool hasFlags = false;

    final int flag1Present = b.readBits(1) & 1;
    logger.t('EPG: Flag1 present=$flag1Present');
    if (flag1Present == 1) {
      flags = b.readBits(6) & 0x3F;
      hasFlags = true;
      logger.t('EPG: Flag1 value=0x${flags.toRadixString(16)}');
    }

    final int flag2Present = b.readBits(1) & 1;
    logger.t('EPG: Flag2 present=$flag2Present');
    if (flag2Present == 1) {
      final int flag2 = b.readBits(6) & 0x3F;
      flags |= flag2 << 6;
      hasFlags = true;
      logger.t(
          'EPG: Flag2 value=0x${flag2.toRadixString(16)} combined=0x${flags.toRadixString(16)}');
    }

    if (b.hasError) return -1;

    return hasFlags ? flags : 0xFFC0; // Default when not present
  }

  // Extract duration
  int _extractDuration(BitBuffer b, int baseTime, bool forceRead) {
    // Duration codes lookup table
    const List<int> durationTable = [
      0, // code 0: 0 seconds
      300, // code 1: 5 minutes
      600, // code 2: 10 minutes
      900, // code 3: 15 minutes
      1800, // code 4: 30 minutes
      3600, // code 5: 1 hour
    ];

    int durCode = -1;

    if (!forceRead) {
      final int durPresent = b.readBits(1) & 1;
      logger.t('EPG: Duration present=$durPresent');
      if (durPresent == 1) {
        durCode = b.readBits(3) & 0x7;
      }
    } else {
      durCode = b.readBits(3) & 0x7;
    }

    logger.t('EPG: Duration code=$durCode');

    if (b.hasError) return -1;

    if (durCode == -1) {
      logger.t('EPG: Duration not specified, returning 0');
      return 0; // Duration not specified
    }

    if (durCode == 7) {
      // Optional duration: read 9 bits, multiply by 300 (5 minutes)
      final int optDur = b.readBits(9) & 0x1FF;
      if (b.hasError) return -1;
      final int result = optDur * 300;
      logger.t('EPG: Optional duration: $optDur units = ${result}s');
      return result;
    }

    if (durCode == 6) {
      // Special case, duration until end of day
      final int result = 86400 - baseTime;
      logger.t('EPG: Duration until end of day: ${result}s');
      return result;
    }

    if (durCode <= 5) {
      final int result = durationTable[durCode];
      logger.t('EPG: Duration from table[$durCode]: ${result}s');
      return result;
    }

    logger.w('EPG: Invalid duration code: $durCode');
    return 0;
  }

  // Extract topics
  List<int> _extractTopics(BitBuffer b, int topicWidth) {
    final List<int> topics = <int>[];

    if (b.readBits(1) == 1) {
      final int count = (b.readBits(3) & 0x7) + 1;
      for (int i = 0; i < count; i++) {
        final int topic = b.readBits(topicWidth.clamp(1, 16)) &
            ((1 << topicWidth.clamp(1, 16)) - 1);
        topics.add(topic);
        if (b.hasError) break;
      }
    }

    return topics;
  }

  // Extract additional times
  List<int> _extractAdditionalTimes(BitBuffer b) {
    final int present = b.readBits(1) & 1;
    if (present == 0) {
      return const <int>[];
    }
    final int count = (b.readBits(5) & 0x1F) + 1;
    if (b.hasError || count <= 0) return const <int>[];
    final List<int> starts = <int>[];
    for (int i = 0; i < count; i++) {
      final int units = b.readBits(9) & 0x1FF;
      if (b.hasError) break;
      // Values are in 5-minute units (300 seconds)
      starts.add(units * 300);
    }
    logger.t('EPG: Additional start times count: ${starts.length}');
    return starts;
  }

  // Decode program flags
  EpgProgramFlags _decodeFlags(int flags) {
    return EpgProgramFlags(
      featured: (flags & 0x01) != 0,
      highlighted: (flags & 0x02) != 0,
      live: (flags & 0x04) != 0,
      newThis: (flags & 0x08) != 0,
    );
  }

  void _buildStringTableForSegment(_EpgPool pool, int segIdx) {
    final _EpgSegmentState? seg = pool.segments[segIdx];
    if (seg == null) return;
    final List<int> textIndices = seg.getTextAuIndices();
    if (textIndices.isEmpty) return;

    final List<int> aggregated = <int>[];
    int totalCompressedBytes = 0;
    logger.t('EPG: seg=$segIdx building string table: textAUs=$textIndices');
    for (final int idx in textIndices) {
      final List<int>? au = seg.getTextAu(idx);
      if (au == null || au.isEmpty) continue;
      totalCompressedBytes += au.length;

      final BitBuffer bb = BitBuffer(au);
      // Schedule header
      bb.skipBits(4); // version
      bb.skipBits(3); // type
      bb.skipBits(1); // isText
      bb.skipBits(5); // segVer
      bb.skipBits(16); // epoch
      bb.skipBits(3); // segCnt
      bb.skipBits(3); // segIdx
      // TEXT header
      bb.skipBits(16);
      bb.skipBits(24);
      // Optional AU index header
      if (bb.readBits(1) == 1) {
        final int width = bb.readBits(4) + 1;
        bb.skipBits(width); // total
        bb.skipBits(width); // index
      }
      // Align to byte boundary and append remaining bytes
      bb.align();
      final List<int> rem = bb.remainingData;
      if (rem.isNotEmpty) {
        aggregated.addAll(rem);
        logger.t(
            'EPG: seg=$segIdx TEXT AU[$idx] contributes ${rem.length} bytes (aligned)');
      } else {
        logger.w(
            'EPG: seg=$segIdx TEXT AU[$idx] contributes 0 bytes after align - check headers');
      }
    }

    if (aggregated.isEmpty) {
      logger.w(
          'EPG: seg=$segIdx no compressed data aggregated from ${textIndices.length} TEXT AUs');
      return;
    }

    logger.t(
        'EPG: seg=$segIdx aggregated compressed data: ${aggregated.length} bytes (from ${textIndices.length} AUs, total raw=${totalCompressedBytes}B) head[32]=${_hexSample(aggregated, maxBytes: 32)}');
    // Full byte dump
    _logBase64Dump('EPG: seg=$segIdx TEXT aggregated', aggregated);

    // Decompress the aggregated buffer
    // Try standard zlib first (Header indicates zlib format)
    try {
      final List<int> decompressed = io.ZLibCodec().decode(aggregated);
      final List<String> strings = _splitZeroTerminatedUtf8(decompressed);
      pool.stringTables[segIdx] = strings;
      pool.stringTablesById[segIdx] = strings;
      pool.segmentToStringTableId[segIdx] = segIdx;
      logger.d(
          'EPG: seg=$segIdx stringTable built successfully: ${aggregated.length}B compressed -> ${decompressed.length}B -> ${strings.length} strings');
    } catch (e) {
      logger
          .w('EPG: seg=$segIdx zlib decode failed: $e, trying raw deflate...');
      // Fallback to raw deflate on aggregated stream
      try {
        final List<int> decompressed =
            io.ZLibCodec(raw: true).decode(aggregated);
        final List<String> strings = _splitZeroTerminatedUtf8(decompressed);
        pool.stringTables[segIdx] = strings;
        pool.stringTablesById[segIdx] = strings;
        pool.segmentToStringTableId[segIdx] = segIdx;
        logger.d(
            'EPG: seg=$segIdx stringTable built with raw deflate: ${aggregated.length}B -> ${decompressed.length}B -> ${strings.length} strings');
      } catch (e2) {
        logger.w(
            'EPG: seg=$segIdx both zlib and raw deflate failed: zlib=$e, raw=$e2 (aggregated=${aggregated.length}B from ${textIndices.length} AUs). Trying per-AU decode...');

        // Final fallback, try decoding each AU's payload individually
        final List<int> decompressedParts = <int>[];
        for (final int idx in textIndices) {
          final List<int>? au = seg.getTextAu(idx);
          if (au == null || au.isEmpty) continue;

          // Re-parse to isolate this AU's compressed payload
          final BitBuffer bb = BitBuffer(au);
          bb.skipBits(4); // version
          bb.skipBits(3); // type
          bb.skipBits(1); // isText
          bb.skipBits(5); // segVer
          bb.skipBits(16); // epoch
          bb.skipBits(3); // segCnt
          bb.skipBits(3); // segIdx
          bb.skipBits(16);
          bb.skipBits(24);
          if (bb.readBits(1) == 1) {
            final int width = bb.readBits(4) + 1;
            bb.skipBits(width);
            bb.skipBits(width);
          }
          bb.align();
          final List<int> rem = bb.remainingData;
          if (rem.isEmpty) {
            logger.w('EPG: seg=$segIdx per-AU[$idx]: no bytes after align');
            continue;
          }
          // Dump per-AU compressed payload
          _logBase64Dump('EPG: seg=$segIdx TEXT per-AU[$idx] compressed', rem);
          // Try standard zlib first for this AU
          try {
            final List<int> part = io.ZLibCodec().decode(rem);
            decompressedParts.addAll(part);
            logger.t(
                'EPG: seg=$segIdx per-AU[$idx] zlib OK -> ${part.length} bytes');
            continue;
          } catch (e3) {
            logger.t('EPG: seg=$segIdx per-AU[$idx] zlib failed: $e3');
          }
          // Try raw deflate for this AU
          try {
            final List<int> part = io.ZLibCodec(raw: true).decode(rem);
            decompressedParts.addAll(part);
            logger.t(
                'EPG: seg=$segIdx per-AU[$idx] raw-deflate OK -> ${part.length} bytes');
          } catch (e4) {
            logger.w('EPG: seg=$segIdx per-AU[$idx] raw-deflate failed: $e4');
          }
        }

        if (decompressedParts.isNotEmpty) {
          // Dump combined decompressed bytes
          _logBase64Dump('EPG: seg=$segIdx TEXT per-AU combined decompressed',
              decompressedParts);
          final List<String> strings =
              _splitZeroTerminatedUtf8(decompressedParts);
          pool.stringTables[segIdx] = strings;
          pool.stringTablesById[segIdx] = strings;
          pool.segmentToStringTableId[segIdx] = segIdx;
          logger.d(
              'EPG: seg=$segIdx stringTable built from per-AU decode: total ${decompressedParts.length}B -> ${strings.length} strings');
        }
      }
    }
  }
}

class _EpgPool {
  final int epoch;
  int totalSegments;
  int scheduleVersion = 0;
  final Map<int, _EpgSegmentState> segments = <int, _EpgSegmentState>{};
  final Map<int, List<String>> stringTables = <int, List<String>>{};
  // Maintain optional per-table-id string tables and a mapping from segment
  // index to table id for lookups when resolving strings
  final Map<int, List<String>> stringTablesById = <int, List<String>>{};
  final Map<int, int> segmentToStringTableId = <int, int>{};
  final Map<int, _EpgDaySchedule> extracted = <int, _EpgDaySchedule>{};
  bool scheduleExtractionInProgress = false;

  _EpgPool({required this.epoch, required this.totalSegments}) {
    for (int i = 0; i < totalSegments; i++) {
      segments[i] = _EpgSegmentState(i);
    }
  }

  void expandSegmentsTo(int newTotal) {
    if (newTotal <= totalSegments) return;
    for (int i = totalSegments; i < newTotal; i++) {
      segments[i] = _EpgSegmentState(i);
    }
    totalSegments = newTotal;
  }

  void shrinkSegmentsTo(int newTotal) {
    if (newTotal >= totalSegments) return;
    for (int i = newTotal; i < totalSegments; i++) {
      segments.remove(i);
      stringTables.remove(i);
      segmentToStringTableId.remove(i);
      extracted.remove(i);
    }
    totalSegments = newTotal;
  }

  int countAssembledSegments() {
    int count = 0;
    for (int i = 0; i < totalSegments; i++) {
      final _EpgSegmentState? s = segments[i];
      if (s != null && s.isAssembled) count++;
    }
    return count;
  }
}

class _EpgSegmentState {
  final int index;
  int version = 0;
  int gridTotal = 0;
  int textTotal = 0;
  int? sidWidth;
  int? progCountWidth;
  int? durationWidth;
  int? topicWidth;
  final Map<int, List<int>> _gridAus = <int, List<int>>{};
  final Map<int, List<int>> _textAus = <int, List<int>>{};
  _EpgDaySchedule? extracted;

  _EpgSegmentState(this.index);

  int get gridReceivedCount => _gridAus.length;
  int get textReceivedCount => _textAus.length;
  bool get isAssembled {
    final bool gridOk = gridTotal == 0 || gridReceivedCount == gridTotal;
    final bool textOk = textTotal == 0 || textReceivedCount == textTotal;
    return gridReceivedCount > 0 && textReceivedCount > 0 && gridOk && textOk;
  }

  void resetContent() {
    gridTotal = 0;
    textTotal = 0;
    _gridAus.clear();
    _textAus.clear();
    extracted = null;
  }

  bool addGridAu(int idx, List<int> bytes) {
    if (idx < 0) idx = 0;
    if (_gridAus.containsKey(idx)) return false;
    _gridAus[idx] = List<int>.from(bytes);
    return true;
  }

  bool addTextAu(int idx, List<int> bytes) {
    if (idx < 0) idx = 0;
    if (_textAus.containsKey(idx)) return false;
    _textAus[idx] = List<int>.from(bytes);
    return true;
  }

  List<int> combineGridBytes() {
    if (_gridAus.isEmpty) return const <int>[];
    final List<int> keys = _gridAus.keys.toList()..sort();
    final List<int> out = <int>[];
    for (final int k in keys) {
      out.addAll(_gridAus[k]!);
    }
    return out;
  }

  List<int> combineTextBytes() {
    if (_textAus.isEmpty) return const <int>[];
    final List<int> keys = _textAus.keys.toList()..sort();
    final List<int> out = <int>[];
    for (final int k in keys) {
      out.addAll(_textAus[k]!);
    }
    return out;
  }

  List<int> getTextAuIndices() => _textAus.keys.toList()..sort();
  List<int>? getTextAu(int idx) => _textAus[idx];
}

class _EpgDaySchedule {
  final int segmentIndex;
  final List<_EpgProgramEvent> events = <_EpgProgramEvent>[];
  _EpgDaySchedule({required this.segmentIndex});
  void addEvent(_EpgProgramEvent ev) => events.add(ev);
}

class _EpgProgramEvent {
  final int sid;
  final int flags;
  final List<int> topics;
  int durationSeconds;
  int startSeconds;
  String? title;
  String? subtitle;
  Map<String, int>? stringIndices;
  bool advanceOnly;
  final List<int> additionalStarts;
  final int additionalDaysMask;
  _EpgProgramEvent({
    required this.sid,
    required this.flags,
    required this.durationSeconds,
    required this.topics,
    this.stringIndices,
    this.advanceOnly = false,
    this.additionalStarts = const <int>[],
    this.additionalDaysMask = 0,
  }) : startSeconds = 0;
  _EpgProgramEvent.empty()
      : sid = 0,
        flags = 0,
        topics = const <int>[],
        durationSeconds = -1,
        startSeconds = 0,
        stringIndices = null,
        advanceOnly = false,
        additionalStarts = const <int>[],
        additionalDaysMask = 0;
  bool get isValid => durationSeconds >= 0;
}

class EpgSegmentView {
  final int segmentIndex;
  final List<EpgProgramEventView> events;
  final List<String>? stringTable;
  final int stringTableSize;
  final int gridReceived;
  final int gridTotal;
  final int textReceived;
  final int textTotal;
  final List<int>? gridIndices;
  final List<int>? textIndices;
  final int? gridBytes;
  final int? textBytes;
  EpgSegmentView({
    required this.segmentIndex,
    required this.events,
    required this.stringTable,
    required this.stringTableSize,
    required this.gridReceived,
    required this.gridTotal,
    required this.textReceived,
    required this.textTotal,
    this.gridIndices,
    this.textIndices,
    this.gridBytes,
    this.textBytes,
  });
}

class EpgProgramEventView {
  final int sid;
  final int startSeconds;
  final int durationSeconds;
  final int flags;
  final EpgProgramFlags decodedFlags;
  final List<int> topics;
  final String? title;
  final String? subtitle;
  EpgProgramEventView({
    required this.sid,
    required this.startSeconds,
    required this.durationSeconds,
    required this.flags,
    required this.decodedFlags,
    required this.topics,
    this.title,
    this.subtitle,
  });
}

enum EpgGetProgramStatus {
  ok,
  notStarted,
  extractionInProgress,
  invalidDay,
  invalidSid,
  invalidTime,
  notFound,
}

class EpgGetProgramResult {
  final EpgGetProgramStatus status;
  final EpgProgramEventView? program;
  const EpgGetProgramResult({required this.status, this.program});
}

class _EpgProgramSlot {
  final int seriesId;
  final int programId;
  final int flags;
  final int duration;
  final Map<String, int> stringIndices;
  final List<int> topics;

  _EpgProgramSlot({
    required this.seriesId,
    required this.programId,
    required this.flags,
    required this.duration,
    required this.stringIndices,
    required this.topics,
  });

  String? resolveString(String type, List<String>? stringTable) {
    final int? idx = stringIndices[type];
    if (idx == null || stringTable == null) return null;
    if (idx < 0 || idx >= stringTable.length) return null;
    return stringTable[idx];
  }
}

class EpgPoolView {
  final int epoch;
  final bool isCurrent;
  final List<EpgSegmentView> segments;
  EpgPoolView(
      {required this.epoch, required this.isCurrent, required this.segments});
}

// Program flags structure
class EpgProgramFlags {
  final bool featured;
  final bool highlighted;
  final bool live;
  final bool newThis;

  EpgProgramFlags({
    required this.featured,
    required this.highlighted,
    required this.live,
    required this.newThis,
  });
}
