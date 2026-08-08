import 'dart:math' as math;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:orbit/crc.dart';
import 'package:orbit/data/radar_overlay.dart';
import 'package:orbit/data/weather/xm_ppmd_decoder.dart';

class XmRadarPacket {
  final int productId;
  final int mode;
  final int payloadLength;
  final int headerLength;
  final int width;
  final int height;
  final DateTime timestampUtc;
  final double centerLatDeg;
  final double centerLonDeg;
  final double spanLonDeg;
  final int geometryCode;
  final Uint8List payload;

  const XmRadarPacket({
    required this.productId,
    required this.mode,
    required this.payloadLength,
    required this.headerLength,
    required this.width,
    required this.height,
    required this.timestampUtc,
    required this.centerLatDeg,
    required this.centerLonDeg,
    required this.spanLonDeg,
    required this.geometryCode,
    required this.payload,
  });

  int get pixelCount => width * height;

  static XmRadarPacket? parse(List<int> message) {
    if (message.length < 0x1D) return null;

    final int productId = message[0] & 0xFF;
    final int mode = message[1] & 0xFF;
    final int payloadLength = _u32le(message, 2);
    final int width = _u16le(message, 0x17);
    final int height = _u16le(message, 0x19);
    final int? maxMode = XmRadarDecoder._maxMode(productId);
    if (maxMode == null || mode > maxMode) return null;
    if (message.length < payloadLength + 0x1D) return null;
    if (width <= 0 || height <= 0) return null;
    if (width > 7000 || height > 6000) return null;
    if (message.length >= payloadLength + 0x1F) {
      final int storedTailCrc = _u16be(message, message.length - 2);
      final int calcTailCrc =
          CRC16.calculate(message.sublist(0, message.length - 2));
      if (storedTailCrc != calcTailCrc) return null;
    }

    final int headerLength =
        (mode > 1 && (message[6] & 0x01) != 0) ? 0x3D : 0x1D;
    if (message.length <= headerLength) return null;

    final int payloadEnd = message.length >= 2
        ? _min(message.length - 2, headerLength + payloadLength + 4)
        : message.length;
    if (payloadEnd <= headerLength) return null;

    final int timestampSeconds = _u32le(message, 0x0F);

    return XmRadarPacket(
      productId: productId,
      mode: mode,
      payloadLength: payloadLength,
      headerLength: headerLength,
      width: width,
      height: height,
      timestampUtc: DateTime.fromMillisecondsSinceEpoch(
        timestampSeconds * 1000,
        isUtc: true,
      ),
      // Converts wire values to degrees
      centerLatDeg: _i32le(message, 0x07) / 1000000.0,
      centerLonDeg: _i32le(message, 0x0B) / 1000000.0,
      spanLonDeg: _u32le(message, 0x13) / 1000000.0,
      geometryCode: _u16le(message, 0x1B),
      payload: Uint8List.fromList(message.sublist(headerLength, payloadEnd)),
    );
  }
}

class XmRadarDecodeResult {
  final XmRadarPacket packet;
  final Uint8List? indices;
  final RadarOverlay? overlay;
  final String? error;

  const XmRadarDecodeResult({
    required this.packet,
    required this.indices,
    required this.overlay,
    required this.error,
  });
}

class XmRadarDecoder {
  static const Duration _oddModeDecodeTimeout = Duration(seconds: 20);
  static const Duration _convectiveMergeWindow = Duration(minutes: 10);

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

  static const _RadarBounds _fallbackConusBounds = _RadarBounds(
    minLat: 21.5,
    minLon: -127.5,
    maxLat: 50.5,
    maxLon: -64.0,
  );

  static const _RadarBounds _fallbackCanadaBounds = _RadarBounds(
    minLat: 38.0,
    minLon: -141.0,
    maxLat: 70.0,
    maxLon: -52.0,
  );

  static _BaseNexradCache? _lastBaseNexradCache;

  static Future<XmRadarDecodeResult?> decodeAsync(List<int> message) async {
    final XmRadarPacket? packet = XmRadarPacket.parse(message);
    if (packet == null) return null;

    try {
      if ((packet.mode & 0x01) == 0) {
        return _resultFromPackedMode(packet);
      }

      final Uint8List payload = Uint8List.fromList(packet.payload);
      final int pixelCount = packet.pixelCount;
      final Uint8List? indices = await Isolate.run(
        () => XmPpmdDecoder.decode(
          payload,
          expectedOutputLength: pixelCount,
          timeout: _oddModeDecodeTimeout,
        ),
      );
      return _resultFromOddModeIndices(packet, indices);
    } catch (err) {
      return _decodeError(packet, err);
    }
  }

  static XmRadarDecodeResult _resultFromPackedMode(XmRadarPacket packet) {
    final _RadarPlane? plane = _decodePackedMode(packet);
    if (plane == null) {
      return XmRadarDecodeResult(
        packet: packet,
        indices: null,
        overlay: null,
        error: 'XM packed radar decode failed',
      );
    }
    return XmRadarDecodeResult(
      packet: packet,
      indices: plane.indices,
      overlay: _buildOverlay(packet, plane),
      error: null,
    );
  }

  static XmRadarDecodeResult _resultFromOddModeIndices(
    XmRadarPacket packet,
    Uint8List? indices,
  ) {
    if (indices == null) {
      return XmRadarDecodeResult(
        packet: packet,
        indices: null,
        overlay: null,
        error: 'XM custom radar decode failed',
      );
    }

    final _RadarPlane plane = _finalizeDecodedPlane(
      packet,
      _RadarPlane(
        width: packet.width,
        height: packet.height,
        indices: indices,
      ),
    );
    return XmRadarDecodeResult(
      packet: packet,
      indices: plane.indices,
      overlay: _buildOverlay(packet, plane),
      error: null,
    );
  }

  static XmRadarDecodeResult _decodeError(XmRadarPacket packet, Object err) {
    return XmRadarDecodeResult(
      packet: packet,
      indices: null,
      overlay: null,
      error: 'XM radar decode error: $err',
    );
  }

  static _RadarPlane? _decodePackedMode(XmRadarPacket packet) {
    if (packet.payload.length < 8) return null;

    final int stage1Length = _u32le(packet.payload, 0);
    final int stage2Length = _u32le(packet.payload, 4);
    if (stage1Length < 0 || stage2Length < 0) return null;

    final Uint8List source =
        Uint8List.sublistView(packet.payload, 8, packet.payload.length);
    Uint8List stage1;

    if (source.length == stage1Length) {
      stage1 = source;
    } else {
      final List<int> inflated = ZLibDecoder().decodeBytes(source);
      if (inflated.length != stage1Length) return null;
      stage1 = Uint8List.fromList(inflated);
    }

    final Uint8List? stage2 = _expandStage1Rle(stage1, stage2Length);
    if (stage2 == null) return null;

    final Uint8List? indices = _expand2BitRaster(stage2, packet.pixelCount);
    if (indices == null) return null;
    return _finalizeDecodedPlane(
      packet,
      _RadarPlane(width: packet.width, height: packet.height, indices: indices),
    );
  }

  static Uint8List? _expandStage1Rle(Uint8List source, int expectedLength) {
    final Uint8List out = Uint8List(expectedLength);
    int inPos = 0;
    int outPos = 0;

    while (inPos < source.length) {
      final int control = source[inPos++] & 0xFF;
      if ((control & 0x80) != 0) {
        final int runLength = (control & 0x7F) + 2;
        if (outPos + runLength > out.length) return null;
        outPos += runLength;
        continue;
      }

      final int copyLength = control + 1;
      if (inPos + copyLength > source.length) return null;
      if (outPos + copyLength > out.length) return null;
      out.setRange(outPos, outPos + copyLength, source, inPos);
      inPos += copyLength;
      outPos += copyLength;
    }

    return outPos == out.length ? out : null;
  }

  static Uint8List? _expand2BitRaster(Uint8List source, int pixelCount) {
    final Uint8List out = Uint8List(pixelCount);
    int inputPos = 0;
    int value = 0;
    int shift = 1;
    int bitsRemaining = 0;
    int currentByte = 0;
    int outPos = 0;

    int? readPair() {
      if (bitsRemaining == 0) {
        if (inputPos >= source.length) return null;
        currentByte = source[inputPos++] & 0xFF;
        bitsRemaining = 8;
      }
      final int pair = (currentByte & 0xC0) >> 6;
      currentByte = (currentByte << 2) & 0xFF;
      bitsRemaining -= 2;
      return pair;
    }

    while (outPos < pixelCount) {
      final int? pair = readPair();
      if (pair == null) return null;

      if (pair == 0) {
        out[outPos++] = value & 0xFF;
        shift = 1;
        continue;
      }
      if (pair == 1) {
        value = (value + shift) & 0xFF;
        out[outPos++] = value & 0xFF;
        shift = 1;
        continue;
      }
      if (pair == 2) {
        value = (value - shift) & 0xFF;
        out[outPos++] = value & 0xFF;
        shift = 1;
        continue;
      }

      shift++;
      if (shift != 4) {
        continue;
      }

      final int? lowPair = readPair();
      final int? highPair = readPair();
      if (lowPair == null || highPair == null) return null;
      value = (lowPair | (highPair << 2)) & 0xFF;
      out[outPos++] = value;
      shift = 1;
    }

    return out;
  }

  static RadarOverlay _buildOverlay(XmRadarPacket packet, _RadarPlane plane) {
    final Uint8List rgba = Uint8List(plane.width * plane.height * 4);
    for (int i = 0, p = 0; i < plane.indices.length; i++, p += 4) {
      final int level = plane.indices[i] & 0x0F;
      if (level == 0) {
        rgba[p + 0] = 0;
        rgba[p + 1] = 0;
        rgba[p + 2] = 0;
        rgba[p + 3] = 0;
        continue;
      }
      final List<int> rgb = _sampleReflectivityRgb(level);
      rgba[p + 0] = rgb[0] & 0xFF;
      rgba[p + 1] = rgb[1] & 0xFF;
      rgba[p + 2] = rgb[2] & 0xFF;
      rgba[p + 3] = 0xFF;
    }

    final _RadarBounds bounds = _boundsFor(packet);
    return RadarOverlay(
      width: plane.width,
      height: plane.height,
      rgba: rgba,
      minLat: bounds.minLat,
      minLon: bounds.minLon,
      maxLat: bounds.maxLat,
      maxLon: bounds.maxLon,
    );
  }

  static _RadarPlane _finalizeDecodedPlane(
    XmRadarPacket packet,
    _RadarPlane plane,
  ) {
    if (packet.productId == 0x01) {
      _lastBaseNexradCache = _BaseNexradCache(
        timestampUtc: packet.timestampUtc,
        plane: _clonePlane(plane),
      );
    }

    final _RadarPlane mergedPlane =
        packet.productId == 0x1D ? _mergeConvectivePlane(packet, plane) : plane;
    return _postProcessPlane(packet, mergedPlane);
  }

  static _RadarPlane _mergeConvectivePlane(
    XmRadarPacket packet,
    _RadarPlane plane,
  ) {
    final _BaseNexradCache? cache = _lastBaseNexradCache;
    if (cache == null) return plane;
    if (cache.plane.width != plane.width ||
        cache.plane.height != plane.height) {
      return plane;
    }
    if (packet.timestampUtc.difference(cache.timestampUtc) >
        _convectiveMergeWindow) {
      return plane;
    }

    final Uint8List merged = Uint8List.fromList(plane.indices);
    bool changed = false;
    for (int i = 0; i < merged.length; i++) {
      if (merged[i] != 0) continue;
      final int fallback = cache.plane.indices[i] & 0xFF;
      if (fallback == 0) continue;
      // Seems to only back-fill the weakest classes from the base mosaic
      merged[i] = fallback > 2 ? 2 : fallback;
      changed = true;
    }

    if (!changed) return plane;
    return _RadarPlane(
        width: plane.width, height: plane.height, indices: merged);
  }

  static _RadarPlane _postProcessPlane(
    XmRadarPacket packet,
    _RadarPlane plane,
  ) {
    final int? zoom = _zoomFactor(packet);
    if (zoom == null || zoom <= 1) {
      return plane;
    }

    final int outWidth = (plane.width * zoom) + 1;
    final int outHeight = (plane.height * zoom) + 1;
    final Uint8List out = Uint8List(outWidth * outHeight);
    final int inset = zoom == 4 ? 2 : 1;
    final int activeWidth = zoom * (plane.width - 1);
    final int activeHeight = zoom * (plane.height - 1);

    final List<_KernelTap> xTaps = List<_KernelTap>.generate(
      activeWidth,
      (int x) => _kernelTap(x / zoom, plane.width),
      growable: false,
    );
    final List<_KernelTap> yTaps = List<_KernelTap>.generate(
      activeHeight,
      (int y) => _kernelTap(y / zoom, plane.height),
      growable: false,
    );

    for (int y = 0; y < activeHeight; y++) {
      final _KernelTap yt = yTaps[y];
      final int outRow = (y + inset) * outWidth;
      for (int x = 0; x < activeWidth; x++) {
        final _KernelTap xt = xTaps[x];
        double accum = 0.0;
        double total = 0.0;

        for (int yi = 0; yi < yt.indices.length; yi++) {
          final int sy = yt.indices[yi];
          final double wy = yt.weights[yi];
          final int srcRow = sy * plane.width;
          for (int xi = 0; xi < xt.indices.length; xi++) {
            final int sx = xt.indices[xi];
            final double weight = wy * xt.weights[xi];
            if (weight == 0.0) continue;
            accum += ((plane.indices[srcRow + sx] & 0xFF) / 16.0) * weight;
            total += weight;
          }
        }

        if (total > 0.0) {
          final double normalized = accum / total;
          out[outRow + x + inset] =
              ((normalized * 16.0) + 0.5).floor().clamp(0, 15);
        }
      }
    }

    return _RadarPlane(width: outWidth, height: outHeight, indices: out);
  }

  static int? _zoomFactor(XmRadarPacket packet) {
    final double? inferredResolutionKm = _estimateSourceResolutionKm(packet);
    if (inferredResolutionKm != null) {
      final int rounded = inferredResolutionKm.round();
      if ((rounded == 2 || rounded == 4) &&
          (inferredResolutionKm - rounded).abs() <= 0.4) {
        return rounded;
      }
    }

    switch (packet.productId) {
      case 0x01:
      case 0x1D:
        // Resample the base CONUS and convective mosaics onto the display product
        return 4;
      case 0x33:
        return 4;
      case 0x37:
        return 2;
      default:
        return null;
    }
  }

  static double? _estimateSourceResolutionKm(XmRadarPacket packet) {
    if (packet.width <= 1) return null;
    final _RadarBounds bounds = _boundsFor(packet);
    final double centerLat = (bounds.minLat + bounds.maxLat) / 2.0;
    final double spanLon = (bounds.maxLon - bounds.minLon).abs();
    if (!centerLat.isFinite || !spanLon.isFinite || spanLon <= 0.01) {
      return null;
    }

    const double kmPerDegreeAtEquator = 111.32;
    final double totalWidthKm =
        spanLon * kmPerDegreeAtEquator * _cosDegrees(centerLat).abs();
    if (!totalWidthKm.isFinite || totalWidthKm <= 0.1) return null;
    return totalWidthKm / (packet.width - 1);
  }

  // Maximum reflectivity level for a given product
  static int? _maxMode(int productId) {
    switch (productId) {
      case 0x01:
      case 0x1D:
        // Base CONUS mosaic
        return 1;
      case 0x33:
      case 0x34:
      case 0x35:
      case 0x37:
        // Convective mosaic
        return 3;
      default:
        return null;
    }
  }

  static _KernelTap _kernelTap(double position, int sourceSize) {
    final int left = position.floor();
    final int right = left + 1;
    final List<int> indices = <int>[];
    final List<double> weights = <double>[];

    void addTap(int index) {
      final int mirrored = _mirrorIndex(index, sourceSize);
      final double distance = (position - index).abs();
      final double weight = _kernelWeight(distance);
      if (weight <= 0.0) return;
      indices.add(mirrored);
      weights.add(weight);
    }

    addTap(left);
    if (right != left) {
      addTap(right);
    }
    if (indices.isEmpty) {
      indices.add(_mirrorIndex(left, sourceSize));
      weights.add(1.0);
    }
    return _KernelTap(indices: indices, weights: weights);
  }

  static double _kernelWeight(double distance) {
    if (distance >= 1.0) return 0.0;
    return ((2.0 * distance) - 3.0) * distance * distance + 1.0;
  }

  static int _mirrorIndex(int index, int size) {
    if (size <= 1) return 0;
    int v = index;
    while (v < 0 || v >= size) {
      if (v < 0) {
        v = -v;
      } else {
        v = ((size * 2) - v) - 1;
      }
    }
    return v;
  }

  static _RadarPlane _clonePlane(_RadarPlane plane) {
    return _RadarPlane(
      width: plane.width,
      height: plane.height,
      indices: Uint8List.fromList(plane.indices),
    );
  }

  static _RadarBounds _boundsFor(XmRadarPacket packet) {
    final double spanLon =
        packet.spanLonDeg.isFinite && packet.spanLonDeg > 0.01
            ? packet.spanLonDeg
            : _fallbackSpanLon(packet.productId);
    final double centerLat =
        packet.centerLatDeg.isFinite ? packet.centerLatDeg : 0.0;
    final double centerLon =
        packet.centerLonDeg.isFinite ? packet.centerLonDeg : 0.0;
    final double cosLat = _cosDegrees(centerLat).abs().clamp(0.25, 1.0);
    final double latSpan = spanLon * (packet.height / packet.width) * cosLat;
    if (!_isValidLatLon(centerLat, centerLon) || latSpan <= 0.01) {
      return packet.productId == 0x37
          ? _fallbackCanadaBounds
          : _fallbackConusBounds;
    }

    final double halfLon = spanLon / 2.0;
    final double halfLat = latSpan / 2.0;
    return _RadarBounds(
      minLat: _clamp(centerLat - halfLat, -90.0, 90.0),
      minLon: _clamp(centerLon - halfLon, -180.0, 180.0),
      maxLat: _clamp(centerLat + halfLat, -90.0, 90.0),
      maxLon: _clamp(centerLon + halfLon, -180.0, 180.0),
    );
  }

  static double _fallbackSpanLon(int productId) {
    switch (productId) {
      case 0x37:
        return 52.0;
      case 0x33:
        return 30.0;
      default:
        return 30.0;
    }
  }

  static bool _isValidLatLon(double lat, double lon) {
    return lat >= -90.0 &&
        lat <= 90.0 &&
        lon >= -180.0 &&
        lon <= 180.0 &&
        lat.isFinite &&
        lon.isFinite;
  }

  static List<int> _sampleReflectivityRgb(int level) {
    final double dbz = -20.0 + ((level - 1) * (90.0 / 14.0));
    if (dbz <= _dbzStops.first[0]) {
      return _boostPaletteVisibility(_dbzStops.first.sublist(1, 4));
    }
    for (int i = 1; i < _dbzStops.length; i++) {
      final List<int> a = _dbzStops[i - 1];
      final List<int> b = _dbzStops[i];
      final double start = a[0].toDouble();
      final double end = b[0].toDouble();
      if (dbz <= end) {
        final double t = (dbz - start) / (end - start);
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
    final double luma = (0.299 * r) + (0.587 * g) + (0.114 * b);

    int adjust(double channel) {
      final double saturated = luma + ((channel - luma) * 1.18);
      final double brightened = (saturated * 1.06) + 10.0;
      return brightened.round().clamp(0, 255);
    }

    return <int>[adjust(r), adjust(g), adjust(b)];
  }
}

class _RadarPlane {
  final int width;
  final int height;
  final Uint8List indices;

  const _RadarPlane({
    required this.width,
    required this.height,
    required this.indices,
  });
}

class _BaseNexradCache {
  final DateTime timestampUtc;
  final _RadarPlane plane;

  const _BaseNexradCache({
    required this.timestampUtc,
    required this.plane,
  });
}

class _RadarBounds {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  const _RadarBounds({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });
}

class _KernelTap {
  final List<int> indices;
  final List<double> weights;

  const _KernelTap({
    required this.indices,
    required this.weights,
  });
}

int _u16le(List<int> bytes, int offset) {
  if (offset < 0 || offset + 1 >= bytes.length) return 0;
  return (bytes[offset] & 0xFF) | ((bytes[offset + 1] & 0xFF) << 8);
}

int _u16be(List<int> bytes, int offset) {
  if (offset < 0 || offset + 1 >= bytes.length) return 0;
  return ((bytes[offset] & 0xFF) << 8) | (bytes[offset + 1] & 0xFF);
}

int _u32le(List<int> bytes, int offset) {
  if (offset < 0 || offset + 3 >= bytes.length) return 0;
  return (bytes[offset] & 0xFF) |
      ((bytes[offset + 1] & 0xFF) << 8) |
      ((bytes[offset + 2] & 0xFF) << 16) |
      ((bytes[offset + 3] & 0xFF) << 24);
}

int _i32le(List<int> bytes, int offset) {
  final int value = _u32le(bytes, offset);
  return (value & 0x80000000) != 0 ? value - 0x100000000 : value;
}

double _cosDegrees(double degrees) {
  return math.cos(degrees * math.pi / 180.0);
}

double _clamp(double value, double min, double max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

int _min(int a, int b) => a < b ? a : b;
