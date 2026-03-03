// Graphical Weather Handler
import 'dart:collection';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/crc.dart';
import 'package:orbit/data/radar_overlay.dart';
import 'package:orbit/data/weather/graphical_weather_huffman.dart';
import 'package:archive/archive.dart';

class GraphicalWeatherHandler extends DSIHandler {
  static const int _maxPlaybackFrames = 120;
  static const Duration _capturedRetentionWindow = Duration(hours: 1);
  static const double _suspiciousCoverageRejectThreshold = 0.995;
  static const double _dominantIntensityRejectThreshold = 0.985;
  static GraphicalWeatherHandler? _activeInstance;

  GraphicalWeatherHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.sxmWeatherGraphical, sxiLayer) {
    _activeInstance = this;
  }

  static GraphicalWeatherHandler? get activeInstance => _activeInstance;

  // Reflectivity-style ramp
  // [dBZ, R, G, B]
  static const List<List<int>> _dbzStops = <List<int>>[
    <int>[-20, 66, 79, 122],
    <int>[-10, 66, 66, 102],
    <int>[0, 84, 84, 84],
    <int>[10, 0, 100, 0],
    <int>[20, 0, 200, 0],
    <int>[30, 130, 170, 0],
    <int>[40, 248, 184, 0],
    <int>[50, 232, 96, 48],
    <int>[60, 208, 128, 240],
    <int>[70, 160, 92, 208],
  ];

  static final List<List<List<int>>> _nowradPalettesRgba =
      _buildNowradPalettesRgba();
  final LinkedHashMap<int, RadarPlaybackFrame> _framesByTimestampMs =
      LinkedHashMap<int, RadarPlaybackFrame>();

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    final int pvn = bitBuffer.readBits(4);
    // Use 4 bits for carousel ID
    final int carid = bitBuffer.readBits(4);

    if (pvn != 1) {
      return;
    }

    if (carid != 0) {
      return;
    }

    _handleProduct(bitBuffer, unit);
  }

  void _handleProduct(BitBuffer b, AccessUnit unit) {
    final int productTypeBit = b.readBits(1);
    final int productId = b.readBits(9);
    final bool isRaster = productTypeBit == 1;
    final _WeatherTime tValid = _readGraphicalWeatherTime(b);
    final _WeatherTime tIssued =
        _readGraphicalWeatherTime(b, yearHint: tValid.time.year);
    final _WeatherMBR mbr = _readGraphicalWeatherMbr(b);

    if (b.hasError) {
      logger.w('GraphicalWeatherHandler: Header parse error');
      return;
    }

    final List<int> bodyView = b.viewRemainingData;
    final int hash = CRC32.calculate(bodyView);
    logger.i(
        'GraphicalWeatherHandler: PRODUCT pid=$productId type=${isRaster ? 'raster' : 'other'} size=${bodyView.length} hash=0x${hash.toRadixString(16).padLeft(8, '0')}');
    logger.d(
        'GraphicalWeatherHandler: header: valid=${tValid.asString} issued=${tIssued.asString} mbr=${mbr.asString}');
    late final _RasterHeader rh;
    if (isRaster) {
      // Consume raster header from the main buffer so section parsing starts at correct offset
      rh = _readRasterHeader(b);
      logger.i(
          'GraphicalWeatherHandler: raster header rows=${rh.rows} cols=${rh.cols} pixelDepth=${rh.pixelDepth} planeCount=${rh.planeCount} precisions=${rh.precisions} offsets=${rh.offsets}');
    } else {
      // Product PID $productId is not raster, skipping for now
      return;
    }

    logger.t(
        'GraphicalWeatherHandler: Product preview: ${_hexPreview(bodyView, 32)}');

    if (productId == 1 || productId == 130) {
      // NOWRAD precipitation intensity raster
      final int width = rh.cols;
      final int height = rh.rows;
      final int pixelCount = width * height;
      final int planeCount = rh.planeCount;
      final List<Uint8List> planeCandidates = <Uint8List>[];
      int safetyCounter = 0;
      while (b.remainingBytes > 0 && !b.hasError && safetyCounter < 64) {
        safetyCounter++;
        final int icf = b.readBits(4) & 0xF;
        final int sectionType = b.readBits(4) & 0xF;
        final int len0 = b.readBits(8);
        final int len1 = b.readBits(8);
        final int len2 = b.readBits(8);
        final int len3 = b.readBits(8);
        final int sectionLength = (len0 & 0xFF) |
            ((len1 & 0xFF) << 8) |
            ((len2 & 0xFF) << 16) |
            ((len3 & 0xFF) << 24);
        if (b.hasError) break;
        if (icf > 5) {
          logger.w(
              'GraphicalWeather: skip invalid section icf=$icf type=$sectionType len=$sectionLength');
          if (sectionLength > 0 && sectionLength <= b.remainingBytes) {
            b.skipBits(sectionLength * 8);
          } else {
            break;
          }
          continue;
        }
        if (sectionType > 5) {
          logger.w(
              'GraphicalWeather: skip invalid section type icf=$icf type=$sectionType len=$sectionLength');
          if (sectionLength > 0 && sectionLength <= b.remainingBytes) {
            b.skipBits(sectionLength * 8);
          } else {
            break;
          }
          continue;
        }
        if (sectionLength <= 0 || sectionLength > b.remainingBytes) {
          logger.w(
              'GraphicalWeather: invalid section length=$sectionLength rem=${b.remainingBytes}');
          break;
        }
        final List<int> payload = b.readBytes(sectionLength);
        if (b.hasError) break;

        logger.t(
            'GraphicalWeather: section icf=$icf type=$sectionType len=$sectionLength');

        final List<int>? expanded = _expandByIcf(
          icf,
          payload,
          expectedLen: pixelCount,
          targetCols: width,
          targetRows: height,
          sectionType: sectionType,
        );
        if (expanded == null || expanded.isEmpty) {
          logger.w(
              'GraphicalWeather: section expand failed for type=$sectionType icf=$icf len=$sectionLength');
          continue;
        }
        // Treat each expanded section as a whole plane candidate
        final Uint8List plane = expanded is Uint8List
            ? expanded
            : Uint8List.fromList(expanded.length > pixelCount
                ? expanded.sublist(0, pixelCount)
                : expanded);
        planeCandidates.add(plane);
      }

      final _PlanePick pick =
          _pickNowradPlanes(planeCandidates, expectedLen: pixelCount);
      Uint8List? intensityPlane = pick.intensity;
      Uint8List? classPlane = pick.cls;
      if (intensityPlane != null && classPlane != null) {
        logger.d(
            'GraphicalWeather: selected planes intensityIdx=${pick.intensityIndex} classIdx=${pick.classIndex} classFallback=${pick.usedClassFallback} '
            'intensity=[${_compactPlaneSummary(intensityPlane, expectedLen: pixelCount)}] '
            'class=[${_compactPlaneSummary(classPlane, expectedLen: pixelCount)}]');
      }

      if (planeCandidates.isNotEmpty) {
        for (int ci = 0; ci < planeCandidates.length; ci++) {
          final p = planeCandidates[ci];
          final _PlaneStats s = _planeStats(p, expectedLen: pixelCount);
          final String guess = (s.maxV <= 2 && s.nonZero > pixelCount * 0.90)
              ? 'classLike'
              : (s.nonZero == 0)
                  ? 'allZero'
                  : (s.maxV > 2)
                      ? 'intensityLike'
                      : 'lowRange';
          logger.t(
              'GraphicalWeather: planeCandidate[$ci] len=${p.length} min=${s.minV} max=${s.maxV} nonZero=${s.nonZero} -> $guess');
        }
      }

      if (intensityPlane == null || intensityPlane.length < pixelCount) {
        logger.w(
            'GraphicalWeather: missing NOWRAD intensity plane (candidates=${planeCandidates.length}, planeCount=$planeCount)');
        return;
      }

      if (classPlane == null || classPlane.length < pixelCount) {
        logger.w(
            'GraphicalWeather: missing NOWRAD class plane (candidates=${planeCandidates.length}, planeCount=$planeCount)');
        return;
      }

      if (pick.usedClassFallback) {
        logger.w(
            'GraphicalWeather: rejecting tile due to low-confidence class plane (fallback). '
            'pid=$productId ts=${tValid.asString} candidates=${planeCandidates.length}');
        return;
      }

      // Build RGBA image using 3 palettes of 16 colors
      final List<List<List<int>>> palettes = _nowradPalettes();
      final Uint8List rgbaRaw = Uint8List(pixelCount * 4);
      int nonTransparentPixels = 0;
      final List<int> intensityHistogram = List<int>.filled(16, 0);
      final List<int> classHistogram = List<int>.filled(3, 0);

      for (int i = 0, p = 0; i < pixelCount; i++, p += 4) {
        final int intensity = intensityPlane[i] & 0xFF;
        final int classIndex = classPlane[i] & 0xFF;
        // Invalid palette indices abort the tile
        if (intensity > 0x0F || classIndex > 2) {
          logger.w(
              'GraphicalWeather: invalid radar palette index intensity=$intensity class=$classIndex');
          return;
        }

        // Transparent for zero intensity, otherwise use palette
        if (intensity == 0) {
          rgbaRaw[p + 0] = 0;
          rgbaRaw[p + 1] = 0;
          rgbaRaw[p + 2] = 0;
          rgbaRaw[p + 3] = 0;
          intensityHistogram[0]++;
          classHistogram[classIndex]++;
          continue;
        }

        final List<int> c = palettes[classIndex][intensity];
        rgbaRaw[p + 0] = c[0] & 0xFF; // R
        rgbaRaw[p + 1] = c[1] & 0xFF; // G
        rgbaRaw[p + 2] = c[2] & 0xFF; // B
        rgbaRaw[p + 3] = c[3] & 0xFF; // A
        nonTransparentPixels++;
        intensityHistogram[intensity]++;
        classHistogram[classIndex]++;
      }
      final double nonTransparentRatio =
          pixelCount <= 0 ? 0.0 : (nonTransparentPixels / pixelCount);
      final int dominantIntensityCount = intensityHistogram
          .skip(1)
          .fold<int>(0, (prev, c) => c > prev ? c : prev);
      final double dominantIntensityRatio =
          pixelCount <= 0 ? 0.0 : (dominantIntensityCount / pixelCount);
      if (nonTransparentRatio >= _suspiciousCoverageRejectThreshold &&
          dominantIntensityRatio >= _dominantIntensityRejectThreshold) {
        logger.w(
            'GraphicalWeather: rejecting suspicious full-coverage tile coverage=${(nonTransparentRatio * 100).toStringAsFixed(1)}% '
            'dominantIntensity=${(dominantIntensityRatio * 100).toStringAsFixed(1)}% '
            'intensityHist=${_compactHistogram(intensityHistogram)} classHist=${_compactHistogram(classHistogram)} '
            'pid=$productId ts=${tValid.asString}');
        return;
      }
      if (nonTransparentRatio > 0.98 || pick.usedClassFallback) {
        logger.w(
            'GraphicalWeather: suspicious tile coverage=${(nonTransparentRatio * 100).toStringAsFixed(1)}% '
            'classFallback=${pick.usedClassFallback} '
            'intensityHist=${_compactHistogram(intensityHistogram)} '
            'classHist=${_compactHistogram(classHistogram)}');
      } else {
        logger.d(
            'GraphicalWeather: tile coverage=${(nonTransparentRatio * 100).toStringAsFixed(1)}% '
            'intensityHist=${_compactHistogram(intensityHistogram)} '
            'classHist=${_compactHistogram(classHistogram)}');
      }

      // The previous orientation chain reduced to identity
      final int outWidth = width;
      final int outHeight = height;
      final Uint8List rgba = rgbaRaw;

      final RadarOverlay overlay = RadarOverlay(
        width: outWidth,
        height: outHeight,
        rgba: rgba,
        minLat: mbr.minLat,
        minLon: mbr.minLon,
        maxLat: mbr.maxLat,
        maxLon: mbr.maxLon,
      );

      sxiLayer.appState.addRadarOverlay(overlay, tValid.time);
      _capturePlaybackTile(overlay, tValid.time);
      logger.i(
          'GraphicalWeatherHandler: NOWRAD tile added (${outWidth}x$outHeight)');
    }
  }

  void _capturePlaybackTile(RadarOverlay overlay, DateTime timestamp) {
    final DateTime tsUtc = timestamp.toUtc();
    final int tsMs = tsUtc.millisecondsSinceEpoch;
    final RadarPlaybackTile tile = RadarPlaybackTile(
      pngBytes: _overlayToPng(overlay),
      width: overlay.width,
      height: overlay.height,
      minLat: overlay.minLat,
      minLon: overlay.minLon,
      maxLat: overlay.maxLat,
      maxLon: overlay.maxLon,
    );
    final RadarPlaybackFrame existing = _framesByTimestampMs[tsMs] ??
        RadarPlaybackFrame(
          timestampUtc: tsUtc,
          tiles: <RadarPlaybackTile>[],
          minLat: tile.minLat,
          minLon: tile.minLon,
          maxLat: tile.maxLat,
          maxLon: tile.maxLon,
        );
    final List<RadarPlaybackTile> nextTiles =
        List<RadarPlaybackTile>.from(existing.tiles)..add(tile);
    _framesByTimestampMs[tsMs] = existing.copyWith(
      tiles: nextTiles,
      minLat: existing.minLat < tile.minLat ? existing.minLat : tile.minLat,
      minLon: existing.minLon < tile.minLon ? existing.minLon : tile.minLon,
      maxLat: existing.maxLat > tile.maxLat ? existing.maxLat : tile.maxLat,
      maxLon: existing.maxLon > tile.maxLon ? existing.maxLon : tile.maxLon,
    );
    _enforcePlaybackFrameLimits();
  }

  List<RadarPlaybackTimelineEntry> capturedRadarTimelineEntries({
    Duration? window,
    bool includeInProgressLatest = true,
  }) {
    final Duration useWindow = window ?? _capturedRetentionWindow;
    final DateTime nowUtc = DateTime.now().toUtc();
    final int oldestAllowedMs =
        nowUtc.subtract(useWindow).millisecondsSinceEpoch;
    final Map<int, int> countByTsMs = <int, int>{
      for (final entry in _framesByTimestampMs.entries)
        if (entry.key >= oldestAllowedMs) entry.key: entry.value.tileCount,
    };
    if (countByTsMs.isEmpty) return <RadarPlaybackTimelineEntry>[];
    final List<int> sorted = countByTsMs.keys.toList()..sort();
    final int latestTsMs = sorted.last;
    int inferredCompleteTiles = countByTsMs[sorted.first] ?? 0;
    for (final int tsMs in sorted) {
      if (tsMs == latestTsMs) continue;
      final int c = countByTsMs[tsMs] ?? 0;
      if (c > inferredCompleteTiles) inferredCompleteTiles = c;
    }

    final List<RadarPlaybackTimelineEntry> entries =
        <RadarPlaybackTimelineEntry>[];
    for (final int tsMs in sorted) {
      final DateTime ts =
          DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true);
      final int tileCount = countByTsMs[tsMs] ?? 0;
      final bool isLatest = tsMs == latestTsMs;
      final bool isComplete = !isLatest ||
          (inferredCompleteTiles > 0 && tileCount >= inferredCompleteTiles);
      if (!includeInProgressLatest && isLatest && !isComplete) {
        continue;
      }
      entries.add(RadarPlaybackTimelineEntry(
        timestampUtc: ts,
        tileCount: tileCount,
        inferredCompleteTileCount:
            inferredCompleteTiles > 0 ? inferredCompleteTiles : tileCount,
        isComplete: isComplete,
        isLatest: isLatest,
      ));
    }
    return entries;
  }

  List<DateTime> capturedPlayableRadarTimestamps({Duration? window}) {
    return capturedRadarTimelineEntries(
      window: window,
      includeInProgressLatest: false,
    ).map((e) => e.timestampUtc).toList(growable: false);
  }

  RadarPlaybackFrame? frameForTimestamp(DateTime timestamp) {
    return _framesByTimestampMs[timestamp.toUtc().millisecondsSinceEpoch];
  }

  int get cachedPlaybackFrameCount => _framesByTimestampMs.length;

  void _enforcePlaybackFrameLimits() {
    final Duration retention = _capturedRetentionWindow;
    final DateTime nowUtc = DateTime.now().toUtc();
    final int oldestAllowedMs =
        nowUtc.subtract(retention).millisecondsSinceEpoch;
    _framesByTimestampMs.removeWhere((tsMs, _) => tsMs < oldestAllowedMs);

    while (_framesByTimestampMs.length > _maxPlaybackFrames) {
      _framesByTimestampMs.remove(_framesByTimestampMs.keys.first);
    }
  }

  Uint8List _overlayToPng(RadarOverlay o) {
    final img.Image image = img.Image.fromBytes(
      width: o.width,
      height: o.height,
      bytes: o.rgba.buffer,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  String _hexPreview(List<int> bytes, int maxLen) {
    final int n = bytes.length < maxLen ? bytes.length : maxLen;
    final String hex =
        bytes.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    return hex + (bytes.length > n ? ' …' : '');
  }

  _WeatherTime _readGraphicalWeatherTime(BitBuffer b, {int? yearHint}) {
    final int month = b.readBits(4) & 0xF;
    final int day = b.readBits(5) & 0x1F;
    final int hour = b.readBits(5) & 0x1F;
    final int minute = b.readBits(6) & 0x3F;
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 23 ||
        minute >= 60) {
      logger.t(
          'GraphicalWeather: invalid time fields m=$month d=$day h=$hour m=$minute');
      return _WeatherTime(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
    int year;
    if (yearHint != null && yearHint != 0xFFFF) {
      year = yearHint;
    } else {
      final DateTime now = DateTime.now().toUtc();
      final int curYear = now.year;
      final int curMonth = now.month;
      if (month == 1 && curMonth == 12) {
        year = curYear + 1;
      } else if (month == 12 && curMonth == 1) {
        year = curYear - 1;
      } else {
        year = curYear;
      }
    }
    try {
      return _WeatherTime(DateTime.utc(year, month, day, hour, minute));
    } catch (_) {
      logger.w('GraphicalWeather: failed to parse time, using default 0');
      return _WeatherTime(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
  }

  _WeatherMBR _readGraphicalWeatherMbr(BitBuffer b) {
    final int lat1 = unsignedToSignedInt(b.readBits(15), 15);
    final int lon0 = unsignedToSignedInt(b.readBits(16), 16);
    final int lat0 = unsignedToSignedInt(b.readBits(15), 15);
    final int lon1 = unsignedToSignedInt(b.readBits(16), 16);

    double normLon(double d) {
      if (d > 180.0) return d - 360.0;
      if (d < -180.0) return d + 360.0;
      return d;
    }

    final double lon0d = normLon(lon0 / 100.0);
    final double lon1d = normLon(lon1 / 100.0);
    final double lat0d = lat0 / 100.0;
    final double lat1d = lat1 / 100.0;

    return _WeatherMBR(
      lat0d < lat1d ? lat0d : lat1d,
      lon0d,
      lat0d < lat1d ? lat1d : lat0d,
      lon1d,
    );
  }

  List<int>? _expandByIcf(int icf, List<int> payload,
      {int? expectedLen, int? targetCols, int? targetRows, int? sectionType}) {
    try {
      switch (icf) {
        case 0:
          // Raw/copy section
          return payload;
        case 1:
          // Deflate section
          {
            if (payload.length < 2) return null;
            if ((payload[0] & 0xFF) != 0x78) return null;
            final List<int> inflated = ZLibDecoder().decodeBytes(payload);
            return inflated;
          }
        case 2:
          {
            // ICF 2 with sectionType 2 uses deflate, otherwise use Weather-Huffman
            if (sectionType == 2) {
              if (payload.length < 2) return null;
              if ((payload[0] & 0xFF) != 0x78) return null;
              return ZLibDecoder().decodeBytes(payload);
            }

            final int cols = targetCols ?? 0;
            final int rows = targetRows ?? 0;
            if (cols <= 0 || rows <= 0) return null;

            final Uint8List? plane = GraphicalWeatherHuffman.decode(
              payload: payload,
              targetCols: cols,
              targetRows: rows,
            );

            if (plane == null) return null;
            if (plane.isNotEmpty) {
              int minV = 255;
              int maxV = 0;
              for (final v in plane) {
                final int vv = v & 0xFF;
                if (vv < minV) minV = vv;
                if (vv > maxV) maxV = vv;
              }
              logger.t(
                  'GraphicalWeather: ICF=2 decoded plane len=${plane.length} min=$minV max=$maxV type=$sectionType');
            }
            if (expectedLen != null && expectedLen > 0) {
              if (plane.length != expectedLen) {
                logger.w(
                    'GraphicalWeather: ICF=2 decode length mismatch got=${plane.length} expected=$expectedLen (type=$sectionType)');
              }
            }
            return plane;
          }
        case 3:
          // Nibble-RLE (no deflate)
          return _expandNibbleRunLengthEncoded(payload);
        case 4:
          // Deflate and then nibble-RLE
          {
            if (payload.length < 2) return null;
            if ((payload[0] & 0xFF) != 0x78) return null;
            final List<int> inflated = ZLibDecoder().decodeBytes(payload);
            if (inflated.isEmpty) return null;
            return _expandNibbleRunLengthEncoded(inflated);
          }
        case 5:
          // Skip 5-byte preheader, deflate, nibble-RLE
          {
            if (payload.length < 7) return null;
            final List<int> body = payload.sublist(5);
            if ((body[0] & 0xFF) != 0x78) return null;
            final List<int> inflated = ZLibDecoder().decodeBytes(body);
            if (inflated.isEmpty) return null;
            return _expandNibbleRunLengthEncoded(inflated);
          }
        default:
          // Don't care about the others
          return null;
      }
    } catch (e) {
      logger.w('GraphicalWeather: Section expand failed icf=$icf: $e');
      return null;
    }
  }

  List<int> _expandNibbleRunLengthEncoded(List<int> src) {
    final List<int> out = <int>[];
    int hiNibblePrefix = 0;
    for (int i = 0; i < src.length; i++) {
      final int b = src[i] & 0xFF;
      final int hi = (b >> 4) & 0xF;
      final int lo = b & 0xF;
      if (b < 0xD0) {
        final int run = hi + 1;
        final int v = (hiNibblePrefix | lo) & 0xFF;
        for (int k = 0; k < run; k++) {
          out.add(v);
        }
        continue;
      }
      if (hi == 0xF) {
        hiNibblePrefix = (b << 4) & 0xFF;
        continue;
      }
      int run = 0;
      if (hi == 0xE) {
        if (i + 1 >= src.length) break;
        run = src[++i] & 0xFF;
      } else if (hi == 0xD) {
        if (i + 2 >= src.length) break;
        run = (src[i + 1] & 0xFF) | ((src[i + 2] & 0xFF) << 8);
        i += 2;
      } else {
        continue;
      }
      final int v = (hiNibblePrefix | lo) & 0xFF;
      for (int k = 0; k < run + 1; k++) {
        out.add(v);
      }
    }
    return out;
  }

  // 3 classes x 16 entries, intensity 0 is transparent
  List<List<List<int>>> _nowradPalettes() {
    return _nowradPalettesRgba;
  }

  static List<List<List<int>>> _buildNowradPalettesRgba() {
    final List<List<List<int>>> out = List<List<List<int>>>.generate(
      3,
      (_) => List<List<int>>.generate(16, (_) => <int>[0, 0, 0, 0]),
    );

    for (int classIndex = 0; classIndex < 3; classIndex++) {
      out[classIndex][0] = <int>[0, 0, 0, 0];
      for (int intensity = 0; intensity < 16; intensity++) {
        if (intensity == 0) continue;
        final double dbz = -20.0 + ((intensity - 1) * (90.0 / 14.0));
        final List<int> rgb = _sampleReflectivityRgb(dbz);
        out[classIndex][intensity] = <int>[rgb[0], rgb[1], rgb[2], 255];
      }
    }

    return out;
  }

  static List<int> _sampleReflectivityRgb(double dbz) {
    if (dbz <= _dbzStops.first[0]) {
      return _boostPaletteVisibility(_dbzStops.first.sublist(1, 4));
    }
    for (int i = 1; i < _dbzStops.length; i++) {
      final List<int> a = _dbzStops[i - 1];
      final List<int> b = _dbzStops[i];
      final double da = a[0].toDouble();
      final double db = b[0].toDouble();
      if (dbz <= db) {
        final double t = (dbz - da) / (db - da);
        int lerp(int x, int y) => (x + ((y - x) * t)).round().clamp(0, 255);
        return _boostPaletteVisibility(<int>[
          lerp(a[1], b[1]),
          lerp(a[2], b[2]),
          lerp(a[3], b[3]),
        ]);
      }
    }
    return _boostPaletteVisibility(_dbzStops.last.sublist(1, 4));
  }

  static List<int> _boostPaletteVisibility(List<int> rgb) {
    final double r = rgb[0].toDouble();
    final double g = rgb[1].toDouble();
    final double b = rgb[2].toDouble();

    // Slight saturation and brightness lift for better visibility
    final double luma = (0.299 * r) + (0.587 * g) + (0.114 * b);
    int adj(double c) {
      final double saturated = luma + ((c - luma) * 1.18);
      final double brightened = (saturated * 1.06) + 10.0;
      return brightened.round().clamp(0, 255);
    }

    return <int>[adj(r), adj(g), adj(b)];
  }
}

class _WeatherTime {
  final DateTime time;
  _WeatherTime(this.time);
  String get asString => time.toIso8601String();
}

class RadarPlaybackFrame {
  final DateTime timestampUtc;
  final List<RadarPlaybackTile> tiles;
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  RadarPlaybackFrame({
    required DateTime timestampUtc,
    required this.tiles,
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  }) : timestampUtc = timestampUtc.toUtc();

  int get tileCount => tiles.length;

  RadarPlaybackFrame copyWith({
    DateTime? timestampUtc,
    List<RadarPlaybackTile>? tiles,
    double? minLat,
    double? minLon,
    double? maxLat,
    double? maxLon,
  }) {
    return RadarPlaybackFrame(
      timestampUtc: timestampUtc ?? this.timestampUtc,
      tiles: tiles ?? this.tiles,
      minLat: minLat ?? this.minLat,
      minLon: minLon ?? this.minLon,
      maxLat: maxLat ?? this.maxLat,
      maxLon: maxLon ?? this.maxLon,
    );
  }
}

class RadarPlaybackTile {
  final Uint8List pngBytes;
  final int width;
  final int height;
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  const RadarPlaybackTile({
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });
}

class RadarPlaybackTimelineEntry {
  final DateTime timestampUtc;
  final int tileCount;
  final int inferredCompleteTileCount;
  final bool isComplete;
  final bool isLatest;

  RadarPlaybackTimelineEntry({
    required DateTime timestampUtc,
    required this.tileCount,
    required this.inferredCompleteTileCount,
    required this.isComplete,
    required this.isLatest,
  }) : timestampUtc = timestampUtc.toUtc();

  double get progress {
    final int denom =
        inferredCompleteTileCount <= 0 ? 1 : inferredCompleteTileCount;
    final double ratio = tileCount / denom;
    return ratio.clamp(0.0, 1.0);
  }
}

class _WeatherMBR {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;
  _WeatherMBR(this.minLat, this.minLon, this.maxLat, this.maxLon);
  String get asString => '[Lat [$minLat -> $maxLat] Lon [$minLon -> $maxLon]]';
}

class _RasterHeader {
  final int rows;
  final int cols;
  final int pixelDepth;
  final int planeCount;
  final List<int> precisions;
  final List<int> offsets;
  _RasterHeader({
    required this.rows,
    required this.cols,
    required this.pixelDepth,
    required this.planeCount,
    required this.precisions,
    required this.offsets,
  });
}

class _PlanePick {
  final Uint8List? intensity;
  final Uint8List? cls;
  final int intensityIndex;
  final int classIndex;
  final bool usedClassFallback;
  const _PlanePick({
    required this.intensity,
    required this.cls,
    required this.intensityIndex,
    required this.classIndex,
    required this.usedClassFallback,
  });
}

class _PlaneStats {
  final int minV;
  final int maxV;
  final int nonZero;
  const _PlaneStats(
      {required this.minV, required this.maxV, required this.nonZero});
}

_PlaneStats _planeStats(Uint8List p, {required int expectedLen}) {
  if (p.isEmpty || expectedLen <= 0) {
    return const _PlaneStats(minV: 0, maxV: 0, nonZero: 0);
  }
  final int n = p.length < expectedLen ? p.length : expectedLen;
  int minV = 255;
  int maxV = 0;
  int nonZero = 0;
  for (int i = 0; i < n; i++) {
    final int v = p[i] & 0xFF;
    if (v != 0) nonZero++;
    if (v < minV) minV = v;
    if (v > maxV) maxV = v;
  }
  if (n == 0) minV = 0;
  return _PlaneStats(minV: minV, maxV: maxV, nonZero: nonZero);
}

_PlanePick _pickNowradPlanes(List<Uint8List> candidates,
    {required int expectedLen}) {
  if (candidates.isEmpty) {
    return const _PlanePick(
      intensity: null,
      cls: null,
      intensityIndex: -1,
      classIndex: -1,
      usedClassFallback: false,
    );
  }

  // Pick strongest-range plane as intensity
  Uint8List? bestIntensity;
  int bestIntensityIndex = -1;
  int bestIntensityMax = -1;
  int bestIntensityNonZero = -1;

  for (int i = 0; i < candidates.length; i++) {
    final p = candidates[i];
    if (p.length < expectedLen) continue;
    final _PlaneStats s = _planeStats(p, expectedLen: expectedLen);
    if (s.maxV > bestIntensityMax ||
        (s.maxV == bestIntensityMax && s.nonZero > bestIntensityNonZero)) {
      bestIntensity = p;
      bestIntensityIndex = i;
      bestIntensityMax = s.maxV;
      bestIntensityNonZero = s.nonZero;
    }
  }

  Uint8List? bestClass;
  int bestClassIndex = -1;
  bool usedClassFallback = false;
  int bestClassNonZero = -1;
  for (int i = 0; i < candidates.length; i++) {
    final p = candidates[i];
    if (p.length < expectedLen) continue;
    if (bestIntensity != null && identical(p, bestIntensity)) continue;
    final _PlaneStats s = _planeStats(p, expectedLen: expectedLen);
    if (s.maxV <= 2 && s.nonZero > bestClassNonZero) {
      bestClass = p;
      bestClassIndex = i;
      bestClassNonZero = s.nonZero;
    }
  }

  // Reject low-confidence class planes
  usedClassFallback = bestClass == null;

  return _PlanePick(
    intensity: bestIntensity,
    cls: bestClass,
    intensityIndex: bestIntensityIndex,
    classIndex: bestClassIndex,
    usedClassFallback: usedClassFallback,
  );
}

String _compactPlaneSummary(Uint8List p, {required int expectedLen}) {
  final _PlaneStats s = _planeStats(p, expectedLen: expectedLen);
  final int n = p.length < expectedLen ? p.length : expectedLen;
  int distinct = 0;
  final Set<int> seen = <int>{};
  for (int i = 0; i < n; i++) {
    seen.add(p[i] & 0xFF);
    if (seen.length > 6) break;
  }
  distinct = seen.length;
  final double ratio = n <= 0 ? 0.0 : (s.nonZero / n);
  return 'min=${s.minV} max=${s.maxV} nonZero=${(ratio * 100).toStringAsFixed(1)}% distinct~$distinct';
}

String _compactHistogram(List<int> hist) {
  final List<String> parts = <String>[];
  for (int i = 0; i < hist.length; i++) {
    final int c = hist[i];
    if (c <= 0) continue;
    parts.add('$i:$c');
  }
  return parts.isEmpty ? 'empty' : parts.join(',');
}

_RasterHeader _readRasterHeader(BitBuffer b) {
  final int cols = b.readBits(13);
  final int rows = b.readBits(13);
  final int pixelDepth = b.readBits(3) + 1;
  final int planeCount = b.readBits(3) + 1;
  final int count = planeCount.clamp(0, 8);
  final List<int> precisions = <int>[];
  final List<int> offsets = <int>[];
  for (int i = 0; i < count; i++) {
    precisions.add(b.readBits(8));
    offsets.add(b.readBits(8));
  }

  return _RasterHeader(
    rows: rows,
    cols: cols,
    pixelDepth: pixelDepth,
    planeCount: planeCount,
    precisions: precisions,
    offsets: offsets,
  );
}
