// Tabular Weather Handler
import 'package:orbit/data/baudot.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/data/forecast_parser.dart';
import 'package:orbit/data/rfd.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/crc.dart';
import 'package:orbit/data/wxtab_parser.dart';

class TabularWeatherHandler extends DSIHandler {
  TabularWeatherHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.sxmWeatherTabular, sxiLayer);

  final RfdCollector _rfdCollector = RfdCollector();
  bool _rfdCollecting = false;
  bool _metadataProcessed = false;
  int? _lastMetadataCrc;

  final Map<int, List<WeatherCacheEntry>> _forecastCache =
      <int, List<WeatherCacheEntry>>{};
  final List<WeatherCacheEntry> _skiCache = <WeatherCacheEntry>[];

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    final int pvn = bitBuffer.readBits(4);
    final int carid = bitBuffer.readBits(3);

    logger.t('TabularWeatherHandler: PVN: $pvn CARID: $carid');

    logger.t(
        'TabularWeatherHandler: data: ${_hexPreview(bitBuffer.viewRemainingData, 128)}');

    if (pvn != 1) {
      logger.w('TabularWeatherHandler: Invalid Version: $pvn');
      return;
    }

    if (!_checkAuCrc(unit)) {
      logger.e('TabularWeatherHandler: CRC check failed for AU (CARID $carid)');
      return;
    }

    switch (carid) {
      case 0:
        logger.d('TabularWeatherHandler: Forecast AU received');
        _handleForecast(bitBuffer, unit);
        break;
      case 1:
        logger.d('TabularWeatherHandler: Ski Condition AU received');
        _handleSkiCond(bitBuffer, unit);
        break;
      case 2:
        // Reliable File Delivery (Weather Data)
        logger.d('TabularWeatherHandler: RFD AU received');
        _handleRfdData(bitBuffer);
        break;
      case 3:
        // Metadata update for RFD
        // Skip if identical metadata already processed
        if (_metadataProcessed && _lastMetadataCrc == unit.crc) {
          logger.t(
              'TabularWeatherHandler: RFD: metadata already processed (crc matches)');
        } else {
          final bool started = _handleRfdMetadata(bitBuffer);
          if (started) {
            _metadataProcessed = true;
            _lastMetadataCrc = unit.crc;
          } else {
            logger.t(
                'TabularWeatherHandler: RFD metadata not started (incomplete/invalid), will re-parse next time');
          }
        }
        break;
      default:
        logger.w('TabularWeatherHandler: Unknown CARID $carid');
        break;
    }
  }

  void _addOrUpdateEntry(
      List<WeatherCacheEntry> cache, WeatherCacheEntry newEntry) {
    final DateTime now = DateTime.now();
    // If same hash/loc/state within 30s, just update timestamp
    for (final WeatherCacheEntry e in cache) {
      if (e.hash == newEntry.hash &&
          e.locId == newEntry.locId &&
          e.state == newEntry.state) {
        if (e.timestamp.add(const Duration(seconds: 30)).isAfter(now)) {
          e.timestamp = now;
          return;
        }
      }
    }

    cache.add(newEntry);
    while (cache.length > 3) {
      cache.removeAt(0); // Drop oldest
    }
  }

  void _handleForecast(BitBuffer b, AccessUnit unit) {
    final int forecastType = b.readBits(4);
    logger.t('TabularWeatherHandler: Forecast: type=$forecastType');
    if (forecastType >= 10) {
      logger.w(
          'TabularWeatherHandler: Forecast: type out of range: $forecastType');
      return;
    }

    final int aseq = b.readBits(2);
    final int locId = b.readBits(7);
    logger.t('TabularWeatherHandler: Forecast: aseq=$aseq locId=$locId');
    int state;
    if (aseq == 3) {
      state = b.readBits(6);
    } else if (aseq == 2) {
      // Derive state from body when ASEQ==2 instead of defaulting to 1
      final int? derived = _deriveFirstStateFromBody(unit.data);
      state = derived ?? 1;
    } else {
      logger.w(
          'TabularWeatherHandler: Forecast: invalid ASEQ for first location: $aseq');
      return;
    }
    logger.t('TabularWeatherHandler: Forecast: state=$state');

    if (b.hasError) {
      logger.w(
          'TabularWeatherHandler: Forecast: bitbuffer error while reading header');
      return;
    }

    // Remaining AU body from AU payload to preserve original packing
    final List<int> body = unit.data;
    if (body.isEmpty) {
      logger.w('TabularWeatherHandler: Forecast: empty AU body');
      return;
    }

    try {
      final ForecastRecord? rec = parseForecastFor(state, locId, body);
      logger.i(
          'TabularWeatherHandler: Forecast recv: type=$forecastType state=$state loc=$locId event=${rec?.eventCode ?? -1} ${rec?.toString() ?? ''}');
    } catch (_) {}

    final int hash = CRC32.calculate(body);
    logger.t(
        'TabularWeatherHandler: Forecast: bodyLen=${body.length} hash=0x${hash.toRadixString(16).padLeft(8, '0')}');
    final WeatherCacheEntry entry = WeatherCacheEntry(
      hash: hash,
      locId: locId,
      state: state,
      size: body.length,
      data: body,
      timestamp: DateTime.now(),
    );

    final List<WeatherCacheEntry> cache =
        _forecastCache.putIfAbsent(forecastType, () => <WeatherCacheEntry>[]);
    _addOrUpdateEntry(cache, entry);

    logger.i(
        'TabularWeatherHandler: Forecast: saved type $forecastType (State: $state, LocId: $locId, size: ${body.length})');
  }

  void _handleSkiCond(BitBuffer b, AccessUnit unit) {
    final int aseq = b.readBits(2);
    final int locId = b.readBits(7);
    logger.t('TabularWeatherHandler: Ski: aseq=$aseq locId=$locId');
    int state;
    if (aseq == 3) {
      state = b.readBits(6);
    } else if (aseq == 2) {
      // Derive state from body when ASEQ==2 instead of defaulting to 1
      final int? derived = _deriveFirstStateFromBody(unit.data);
      state = derived ?? 1;
    } else {
      logger.w(
          'TabularWeatherHandler: Ski: invalid ASEQ for first location: $aseq');
      return;
    }
    logger.t('TabularWeatherHandler: Ski: state=$state');

    if (b.hasError) {
      logger.w(
          'TabularWeatherHandler: Ski: bitbuffer error while reading header');
      return;
    }

    // Remaining AU body from AU payload to preserve original packing
    final List<int> body = unit.data;
    if (body.isEmpty) {
      logger.w('TabularWeatherHandler: Ski: empty AU body');
      return;
    }

    // Log parsed event for this state/location (if available)
    try {
      final ForecastRecord? rec = parseForecastFor(state, locId, body);
      logger.i(
          'TabularWeatherHandler: Ski recv: state=$state loc=$locId event=${rec?.eventCode ?? -1}');
    } catch (_) {}

    final int hash = CRC32.calculate(body);
    logger.t(
        'TabularWeatherHandler: Ski: bodyLen=${body.length} hash=0x${hash.toRadixString(16).padLeft(8, '0')}');
    final WeatherCacheEntry entry = WeatherCacheEntry(
      hash: hash,
      locId: locId,
      state: state,
      size: body.length,
      data: body,
      timestamp: DateTime.now(),
    );

    _addOrUpdateEntry(_skiCache, entry);
    logger.i(
        'TabularWeatherHandler: Ski: saved (State: $state, LocId: $locId, size: ${body.length})');
  }

  int? _deriveFirstStateFromBody(List<int> body) {
    if (body.isEmpty) return null;
    final BitBuffer bb = BitBuffer(body);
    // Skip initial 11 bits
    bb.readBits(11);
    int curState = 0;
    int curLoc = 0;
    while (!bb.hasError) {
      final int tag = bb.readBits(2);
      if (bb.hasError) break;
      switch (tag) {
        case 0:
          curLoc = (curLoc + 1) & 0x3F;
          break;
        case 1:
          curLoc = bb.readBits(6);
          break;
        case 2:
          curState = bb.readBits(7);
          return curState;
        case 3:
          curState = bb.readBits(7);
          curLoc = bb.readBits(6);
          return curState;
        default:
          return null;
      }
    }
    return null;
  }

  bool _checkAuCrc(AccessUnit unit) {
    try {
      return CRC32.check(unit.getHeaderAndData(), unit.crc);
    } catch (_) {
      return false;
    }
  }

  String _hexPreview(List<int> bytes, int maxLen) {
    final int n = bytes.length < maxLen ? bytes.length : maxLen;
    final String hex =
        bytes.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    return hex + (bytes.length > n ? ' …' : '');
  }

  bool _handleRfdMetadata(BitBuffer bitBuffer) {
    logger.t('TabularWeatherHandler: RFD Metadata AU received');
    final RfdMetadata meta = _parseRfdMetadataBits(bitBuffer);
    if (meta.expectedSize == null || meta.expectedSize! <= 0) {
      logger.w(
          'TabularWeatherHandler: RFD: metadata parse invalid or size unknown; not starting collection');
      return false;
    }
    _rfdCollector.start(meta);
    _rfdCollecting = true;
    logger.d(
        'TabularWeatherHandler: RFD: started collection for ${meta.fileName ?? '(no name)'} expectedSize=${meta.expectedSize}');
    return true;
  }

  void _handleRfdData(BitBuffer bitBuffer) {
    bitBuffer.align();
    final List<int> chunk = bitBuffer.remainingData;
    if (chunk.isEmpty) {
      logger.t('TabularWeatherHandler: RFD: empty data AU');
      return;
    }

    if (!_rfdCollecting || !_rfdCollector.inProgress) {
      // Let the collector stage chunks until metadata arrives
      _rfdCollecting = true;
    }

    // Parse block index from first two header bytes
    const int blockHeaderLen = 5;
    if (chunk.length <= blockHeaderLen) {
      logger
          .t('TabularWeatherHandler: RFD: chunk smaller than header, dropping');
      return;
    }
    final int hdrFileId = ((chunk[0] & 0xFF) << 8) | (chunk[1] & 0xFF);
    final int? expected = _rfdCollector.current?.metadata.expectedSize;
    final bool done =
        _rfdCollector.addBlockFromAu(chunk, headerLen: blockHeaderLen);
    final int total = _rfdCollector.current?.receivedSize ?? 0;
    logger.t(
        'TabularWeatherHandler: RFD: chunk ${chunk.length} (fileId $hdrFileId) bytes, total $total${expected != null ? '/$expected' : ''}');
    if (done) {
      final List<int>? fileBytes = _rfdCollector.takeIfComplete();
      if (fileBytes != null) {
        final String preview = _hexPreview(fileBytes, 32);
        logger.i(
            'TabularWeatherHandler: RFD: weather file downloaded (${fileBytes.length} bytes) preview=$preview');

        // Print the bytes
        logger.t('TabularWeatherHandler: RFD: weather file bytes: $fileBytes');

        // Parse the downloaded weather file
        try {
          final parsed = WxTabParser.parse(fileBytes, fileName: null);
          logger.i(
              'TabularWeatherHandler: WxTab parsed: dbVersion=${parsed.dbVersion} fileVersion=${parsed.fileVersion} versionBits=${parsed.fileVersionBits} states=${parsed.states.length}');

          if (parsed.states.isNotEmpty &&
              parsed.states.first.entries.isNotEmpty) {
            final int stateId = parsed.states.first.id;
            final int locId = parsed.states.first.entries.first.index;
            final rec = parseForecastFor(stateId, locId, chunk);
            if (rec != null) {
              logger.i(
                  'TabularWeatherHandler: Forecast sample s=$stateId l=$locId event=${rec.eventCode} tempCur=${rec.tempCur?.toString() ?? 'n/a'}');
            }
          }
        } catch (e) {
          logger.w('TabularWeatherHandler: WxTab parse failed: $e');
        }
        _rfdCollecting = false;
        _metadataProcessed = false;
        _lastMetadataCrc = null;
      }
    }
  }

  // Parse metadata fields
  RfdMetadata _parseRfdMetadataBits(BitBuffer b) {
    // 1) Name in Baudot over exactly 0x10 symbols
    final String name = BaudotDecoder.decodeFixed(b, 0x10, 0x10);

    // 2) 32-bit value
    final int unk32 = b.readBits(32);

    // 3) 4-bit then 3-bit then 3-bit flags
    final int flags4 = b.readBits(4);
    final int type3 = b.readBits(3);
    final int mode3 = b.readBits(3);
    if (type3 > 2 || mode3 >= 2) {
      return const RfdMetadata(
          fileName: null, expectedSize: null, raw: <int>[]);
    }
    logger.t(
        'TabularWeatherHandler: RFD Meta: name=${name.isEmpty ? '(none)' : name} flags4=$flags4 type3=$type3 mode3=$mode3 unk32=0x${unk32.toRadixString(16).padLeft(8, '0')}');

    // 4) 14-bit field
    final int f14 = b.readBits(14);

    // 5) Count = read 4 bits, then +1
    int count = b.readBits(4) + 1;
    final int availableBits = b.remainingBytes * 8;
    final int requiredBits = count * (16 + 14 + 24 + 32);
    logger.t(
        'TabularWeatherHandler: RFD Meta: entries=$count f14=$f14 bitsAvail=$availableBits bitsReq=$requiredBits');

    int totalSize = 0;
    int? entryBlockSize;
    int? firstEntryId;
    for (int i = 0; i < count; i++) {
      final int id16 = b.readBits(16);
      final int blocksOrLen14 = b.readBits(14);
      if (blocksOrLen14 == 0) {
        logger.w('TabularWeatherHandler: RFD Meta: blocksOrLen14 is 0');
        return const RfdMetadata(
            fileName: null, expectedSize: null, raw: <int>[]);
      }
      final int size24 = b.readBits(24);
      final int crc32 = b.readBits(32);
      totalSize += size24;
      if (i == 0) {
        entryBlockSize = blocksOrLen14;
        firstEntryId = id16;
      }
      logger.t(
          'TabularWeatherHandler: RFD Meta Entry[$i]: id16=$id16 blocksOrLen14=$blocksOrLen14 size24=$size24 crc32=0x${crc32.toRadixString(16).padLeft(8, '0')}');
    }

    // 6) Optional trailing fields
    final int hasExtra = b.readBits(1);
    if (hasExtra == 1) {
      final int seven = b.readBits(7);
      if (seven >= 1) {
        b.readBits(10);
      }
      logger.t('TabularWeatherHandler: RFD Meta: extra present, seven=$seven');
    }

    final RfdMetadata meta = RfdMetadata(
        fileName: name.isEmpty ? null : name,
        expectedSize: totalSize,
        blockSize: entryBlockSize,
        fileId: firstEntryId,
        compressionMode: mode3,
        raw: const <int>[]);
    logger.d('TabularWeatherHandler: RFD: metadata parsed: $meta');
    return meta;
  }
}

class WeatherCacheEntry {
  final int hash;
  final int locId;
  final int state;
  final int size;
  final List<int> data;
  DateTime timestamp;

  WeatherCacheEntry({
    required this.hash,
    required this.locId,
    required this.state,
    required this.size,
    required this.data,
    required this.timestamp,
  });
}
