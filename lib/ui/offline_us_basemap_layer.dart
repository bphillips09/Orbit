// Offline US Basemap
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

List<Widget> offlineUsBasemapLayers() {
  return const <Widget>[
    OfflineUsBasemapLayer(),
  ];
}

class OfflineUsBasemapLayer extends StatefulWidget {
  const OfflineUsBasemapLayer({super.key});

  @override
  State<OfflineUsBasemapLayer> createState() => _OfflineUsBasemapLayerState();
}

class _OfflineUsBasemapLayerState extends State<OfflineUsBasemapLayer> {
  late final Future<_BasemapGeometry> _future = _loadBasemapGeometry();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BasemapGeometry>(
      future: _future,
      builder: (context, snapshot) {
        final _BasemapGeometry data = snapshot.data ?? _emptyGeometry;
        return Stack(
          children: <Widget>[
            PolygonLayer(polygons: data.landPolygons),
            PolylineLayer(polylines: data.borderPolylines),
          ],
        );
      },
    );
  }
}

Future<_BasemapGeometry> _loadBasemapGeometry() async {
  try {
    final String raw =
        await rootBundle.loadString('assets/maps/usa_simplified.geojson');
    final dynamic decoded = jsonDecode(raw);
    final List<dynamic> geometries = _extractGeometries(decoded);
    final List<Polygon> polygons = <Polygon>[];
    final List<Polyline> borders = <Polyline>[];
    for (final dynamic g in geometries) {
      final String type =
          (g is Map<String, dynamic> ? g['type'] : null) as String? ?? '';
      final dynamic coords =
          g is Map<String, dynamic> ? g['coordinates'] : null;
      if (coords == null) continue;
      if (type == 'Polygon') {
        _appendPolygonGeometry(coords, polygons, borders);
      } else if (type == 'MultiPolygon') {
        for (final dynamic p in coords as List<dynamic>) {
          _appendPolygonGeometry(p, polygons, borders);
        }
      }
    }
    if (polygons.isEmpty || borders.isEmpty) return _emptyGeometry;
    return _BasemapGeometry(landPolygons: polygons, borderPolylines: borders);
  } catch (_) {
    return _emptyGeometry;
  }
}

List<dynamic> _extractGeometries(dynamic decoded) {
  if (decoded is! Map<String, dynamic>) return <dynamic>[];
  final String? type = decoded['type'] as String?;
  switch (type) {
    case 'GeometryCollection':
      return (decoded['geometries'] as List<dynamic>? ?? <dynamic>[]);
    case 'FeatureCollection':
      return (decoded['features'] as List<dynamic>? ?? <dynamic>[])
          .map((f) => (f as Map<String, dynamic>)['geometry'])
          .where((g) => g != null)
          .toList(growable: false);
    case 'Feature':
      final dynamic g = decoded['geometry'];
      return g == null ? <dynamic>[] : <dynamic>[g];
    case 'Polygon':
    case 'MultiPolygon':
      return <dynamic>[decoded];
    default:
      return <dynamic>[];
  }
}

void _appendPolygonGeometry(
  dynamic polygonCoords,
  List<Polygon> polygons,
  List<Polyline> borders,
) {
  if (polygonCoords is! List<dynamic> || polygonCoords.isEmpty) return;
  final dynamic outerRingRaw = polygonCoords.first;
  if (outerRingRaw is! List<dynamic> || outerRingRaw.length < 3) return;
  final List<LatLng> points = <LatLng>[];
  for (final dynamic pt in outerRingRaw) {
    if (pt is! List || pt.length < 2) continue;
    final double lon = (pt[0] as num).toDouble();
    final double lat = (pt[1] as num).toDouble();
    points.add(LatLng(lat, lon));
  }
  if (points.length < 3) return;
  polygons.add(
    Polygon(
      points: points,
      color: const Color(0xFFF1F2F4),
      borderColor: const Color(0xFFB8BDC7),
      borderStrokeWidth: 0.8,
    ),
  );
  borders.add(
    Polyline(
      points: points,
      strokeWidth: 0.8,
      color: const Color(0xFFAEB5BF),
    ),
  );
}

class _BasemapGeometry {
  final List<Polygon> landPolygons;
  final List<Polyline> borderPolylines;

  const _BasemapGeometry({
    required this.landPolygons,
    required this.borderPolylines,
  });
}

const _BasemapGeometry _emptyGeometry = _BasemapGeometry(
  landPolygons: <Polygon>[],
  borderPolylines: <Polyline>[],
);
