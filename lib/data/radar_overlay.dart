import 'dart:typed_data';

class RadarOverlay {
  final int width;
  final int height;
  final Uint8List rgba;
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  const RadarOverlay({
    required this.width,
    required this.height,
    required this.rgba,
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });
}
