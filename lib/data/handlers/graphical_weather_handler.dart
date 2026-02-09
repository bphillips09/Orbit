// Graphical Weather Handler
import 'dart:typed_data';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/crc.dart';
import 'package:orbit/data/radar_overlay.dart';

class GraphicalWeatherHandler extends DSIHandler {
  GraphicalWeatherHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.sxmWeatherGraphical, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final BitBuffer bitBuffer = BitBuffer(unit.getHeaderAndData());
    final int pvn = bitBuffer.readBits(4);
    // WXAGW uses a 4-bit CARID field
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
    final _WxTime tValid = _readGraphwxTime(b);
    final _WxTime tIssued = _readGraphwxTime(b, yearHint: tValid.time.year);
    final _WxMBR mbr = _readGraphwxMBR(b);

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

    if (productId == 1) {
      // NOWRAD precipitation intensity raster (PID 1)
      final int width = rh.cols;
      final int height = rh.rows;
      final int pixelCount = width * height;
      final int planeCount = rh.planeCount;
      final List<List<int>> planeAgg =
          List<List<int>>.generate(planeCount, (_) => <int>[]);
      final List<int> planeFilled = List<int>.filled(planeCount, 0);
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
        if (sectionLength <= 0 || sectionLength > b.remainingBytes + 8) {
          logger.w('GraphWX: invalid section length: $sectionLength');
          break;
        }
        final List<int> payload = b.readBytes(sectionLength);
        if (b.hasError) break;

        logger.t(
            'GraphWX: section icf=$icf type=$sectionType len=$sectionLength');

        // Skip probable zlib sections regardless of ICF
        if (payload.length >= 2 && (payload[0] & 0xFF) == 0x78) {
          logger.t('GraphWX: skipping zlib/deflate section');
          continue;
        }

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
              'GraphWX: section expand failed for type=$sectionType icf=$icf len=$sectionLength');
          continue;
        }
        // Use as plane index when in range, otherwise fall back to plane 0
        final int dstPlane =
            (sectionType >= 0 && sectionType < planeCount) ? sectionType : 0;
        final List<int> dst = planeAgg[dstPlane];
        final int needed = pixelCount - dst.length;
        if (needed > 0) {
          if (expanded.length <= needed) {
            dst.addAll(expanded);
            planeFilled[dstPlane] = dst.length;
          } else {
            dst.addAll(expanded.sublist(0, needed));
            planeFilled[dstPlane] = dst.length;
          }
        }
        // Stop when all planes are complete
        bool allFull = true;
        for (int pi = 0; pi < planeCount; pi++) {
          if (planeAgg[pi].length < pixelCount) {
            allFull = false;
            break;
          }
        }
        if (allFull) break;
      }

      // Select intensity plane, prefer plane 0, otherwise use the first full plane
      List<int>? intensityPlane =
          planeAgg.isNotEmpty && planeAgg[0].length >= pixelCount
              ? planeAgg[0]
              : null;
      if (intensityPlane == null) {
        for (int pi = 0; pi < planeCount; pi++) {
          if (planeAgg[pi].length >= pixelCount) {
            intensityPlane = planeAgg[pi];
            break;
          }
        }
      }
      if (intensityPlane == null || intensityPlane.length < pixelCount) {
        logger.w('GraphWX: missing NOWRAD intensity plane');
        return;
      }
      final List<int>? classPlane =
          (planeCount > 1 && planeAgg[1].length >= pixelCount)
              ? planeAgg[1]
              : null;

      // Build RGBA image using 3 palettes of 16 colors
      final List<List<List<int>>> palettes = _nowradPalettes();
      final Uint8List rgba = Uint8List(pixelCount * 4);

      for (int i = 0, p = 0; i < pixelCount; i++, p += 4) {
        final int intensity = (intensityPlane[i] & 0xFF).clamp(0, 15);
        final int classIndex =
            classPlane != null ? (classPlane[i] & 0xFF).clamp(0, 2) : 0;

        // Transparent for zero intensity, otherwise use palette
        if (intensity == 0) {
          rgba[p + 0] = 0;
          rgba[p + 1] = 0;
          rgba[p + 2] = 0;
          rgba[p + 3] = 0;
          continue;
        }

        final List<int> c = palettes[classIndex][intensity];
        rgba[p + 0] = c[0] & 0xFF; // R
        rgba[p + 1] = c[1] & 0xFF; // G
        rgba[p + 2] = c[2] & 0xFF; // B
        rgba[p + 3] = c[3] & 0xFF; // A
      }

      final RadarOverlay overlay = RadarOverlay(
        width: width,
        height: height,
        rgba: rgba,
        minLat: mbr.minLat,
        minLon: mbr.minLon,
        maxLat: mbr.maxLat,
        maxLon: mbr.maxLon,
      );

      sxiLayer.appState.addRadarOverlay(overlay, tValid.time);
      logger.i('GraphicalWeatherHandler: NOWRAD tile added (${width}x$height)');
    }
  }

  String _hexPreview(List<int> bytes, int maxLen) {
    final int n = bytes.length < maxLen ? bytes.length : maxLen;
    final String hex =
        bytes.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    return hex + (bytes.length > n ? ' …' : '');
  }

  _WxTime _readGraphwxTime(BitBuffer b, {int? yearHint}) {
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
      logger
          .t('GraphWX: invalid time fields m=$month d=$day h=$hour m=$minute');
      return _WxTime(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
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
      return _WxTime(DateTime.utc(year, month, day, hour, minute));
    } catch (_) {
      logger.w('GraphWX: failed to parse time, using default 0');
      return _WxTime(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    }
  }

  _WxMBR _readGraphwxMBR(BitBuffer b) {
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

    return _WxMBR(
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
        case 2:
          {
            // TODO: Implement Weather-Huffman decode
            return null;
          }
        default:
          // Don't care about the others
          return null;
      }
    } catch (e) {
      logger.w('GraphWX: Section expand failed icf=$icf: $e');
      return null;
    }
  }

  // Approximate NOWRAD palettes, 3 sets x 16 RGBA entries, index 0 is transparent
  // Palette 0: default, palette 1/2: slight hue shifts
  List<List<List<int>>> _nowradPalettes() {
    List<List<int>> base = <List<int>>[
      [0, 0, 0, 0],
      [0, 233, 0, 200],
      [16, 213, 0, 210],
      [32, 193, 0, 220],
      [64, 173, 0, 230],
      [96, 153, 0, 240],
      [128, 133, 0, 250],
      [160, 128, 0, 255],
      [192, 112, 0, 255],
      [224, 96, 0, 255],
      [240, 64, 0, 255],
      [248, 0, 0, 255],
      [216, 0, 96, 255],
      [184, 0, 160, 255],
      [208, 80, 192, 255],
      [240, 240, 240, 255],
    ];

    // Variant palettes with subtle hue shifts
    List<List<int>> variant1 = <List<int>>[
      [0, 0, 0, 0],
      [0, 225, 32, 200],
      [0, 205, 48, 210],
      [0, 185, 64, 220],
      [0, 165, 96, 230],
      [0, 145, 128, 240],
      [0, 125, 160, 250],
      [0, 105, 192, 255],
      [0, 85, 224, 255],
      [0, 64, 240, 255],
      [0, 0, 248, 255],
      [64, 0, 216, 255],
      [112, 0, 184, 255],
      [160, 0, 160, 255],
      [208, 64, 192, 255],
      [240, 240, 240, 255],
    ];

    List<List<int>> variant2 = <List<int>>[
      [0, 0, 0, 0],
      [32, 225, 0, 200],
      [64, 205, 0, 210],
      [96, 185, 0, 220],
      [128, 165, 0, 230],
      [160, 145, 0, 240],
      [192, 125, 0, 250],
      [208, 105, 0, 255],
      [224, 85, 0, 255],
      [240, 64, 0, 255],
      [248, 0, 0, 255],
      [232, 0, 96, 255],
      [216, 0, 160, 255],
      [224, 48, 192, 255],
      [240, 96, 224, 255],
      [255, 255, 255, 255],
    ];

    return <List<List<int>>>[base, variant1, variant2];
  }
}

class _WxTime {
  final DateTime time;
  _WxTime(this.time);
  String get asString => time.toIso8601String();
}

class _WxMBR {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;
  _WxMBR(this.minLat, this.minLon, this.maxLat, this.maxLon);
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
