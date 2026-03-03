import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/crc.dart';
import 'package:orbit/data/handlers/graphical_weather_handler.dart';
import 'package:orbit/data/radar_overlay.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/ui/offline_us_basemap_layer.dart';
import 'package:provider/provider.dart';

class RadarMapDialog extends StatefulWidget {
  final bool embedded;

  const RadarMapDialog({super.key, this.embedded = false});

  static Future<void> show(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const RadarMapDialog(),
    );
  }

  @override
  State<RadarMapDialog> createState() => _RadarMapDialogState();
}

class _RadarMapDialogState extends State<RadarMapDialog> {
  final Map<RadarOverlay, Uint8List> _pngCache = <RadarOverlay, Uint8List>{};
  bool _isLiveMode = true;
  List<RadarPlaybackTimelineEntry> _timelineEntries =
      <RadarPlaybackTimelineEntry>[];
  int _timelineIndex = 0;
  bool _isPlaying = false;
  Timer? _playTimer;
  Timer? _timelineRefreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimeline();
    _timelineRefreshTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _refreshTimeline());
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _timelineRefreshTimer?.cancel();
    super.dispose();
  }

  DateTime? get _selectedTimelineTimestamp {
    if (_timelineEntries.isEmpty) return null;
    final int idx = _timelineIndex.clamp(0, _timelineEntries.length - 1);
    return _timelineEntries[idx].timestampUtc;
  }

  RadarPlaybackTimelineEntry? get _selectedTimelineEntry {
    if (_timelineEntries.isEmpty) return null;
    final int idx = _timelineIndex.clamp(0, _timelineEntries.length - 1);
    return _timelineEntries[idx];
  }

  RadarPlaybackFrame? _frameForTimestamp(DateTime? ts) {
    if (ts == null) return null;
    final GraphicalWeatherHandler? handler =
        GraphicalWeatherHandler.activeInstance;
    if (handler == null) return null;
    return handler.frameForTimestamp(ts);
  }

  void _refreshTimeline() {
    final GraphicalWeatherHandler? handler =
        GraphicalWeatherHandler.activeInstance;
    if (handler == null) return;
    final List<RadarPlaybackTimelineEntry> next =
        handler.capturedRadarTimelineEntries(includeInProgressLatest: true);
    final DateTime? selected = _selectedTimelineTimestamp;

    if (next.isEmpty) {
      if (_timelineEntries.isNotEmpty && mounted) {
        setState(() {
          _timelineEntries = <RadarPlaybackTimelineEntry>[];
          _timelineIndex = 0;
          _isPlaying = false;
        });
      }
      _playTimer?.cancel();
      return;
    }

    int nextIndex = next.length - 1;
    if (selected != null) {
      final int keep = next
          .indexWhere((e) => e.timestampUtc.isAtSameMomentAs(selected.toUtc()));
      if (keep >= 0) {
        nextIndex = keep;
      }
    }

    final bool changed = next.length != _timelineEntries.length ||
        !_sameTimeline(next, _timelineEntries) ||
        nextIndex != _timelineIndex;
    if (!changed || !mounted) return;

    setState(() {
      _timelineEntries = next;
      _timelineIndex = nextIndex;
    });
  }

  bool _sameTimeline(
      List<RadarPlaybackTimelineEntry> a, List<RadarPlaybackTimelineEntry> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!a[i].timestampUtc.isAtSameMomentAs(b[i].timestampUtc)) return false;
      if (a[i].tileCount != b[i].tileCount) return false;
      if (a[i].isComplete != b[i].isComplete) return false;
    }
    return true;
  }

  Future<void> _selectTimelineIndex(int index) async {
    if (_timelineEntries.isEmpty) return;
    final int clamped = index.clamp(0, _timelineEntries.length - 1);
    if (mounted) {
      setState(() {
        _timelineIndex = clamped;
        _isLiveMode = false;
      });
    }
  }

  RadarPlaybackTimelineEntry? _referenceCompleteEntryFor(
      RadarPlaybackTimelineEntry? selected) {
    if (selected == null) return null;
    for (int i = _timelineEntries.length - 1; i >= 0; i--) {
      final RadarPlaybackTimelineEntry e = _timelineEntries[i];
      if (!e.isComplete) continue;
      if (e.timestampUtc.isAtSameMomentAs(selected.timestampUtc)) continue;
      if (e.timestampUtc.isBefore(selected.timestampUtc) ||
          e.timestampUtc.isAtSameMomentAs(selected.timestampUtc)) {
        return e;
      }
    }
    for (int i = _timelineEntries.length - 1; i >= 0; i--) {
      final RadarPlaybackTimelineEntry e = _timelineEntries[i];
      if (!e.isComplete) continue;
      if (!e.timestampUtc.isAtSameMomentAs(selected.timestampUtc)) {
        return e;
      }
    }
    return null;
  }

  String _tileKey(double minLat, double minLon, double maxLat, double maxLon) {
    int q(double v) => (v * 100.0).round();
    return '${q(minLat)}:${q(minLon)}:${q(maxLat)}:${q(maxLon)}';
  }

  Set<String> _expectedTileKeysFromCompleteFrames({int maxFrames = 6}) {
    final Set<String> keys = <String>{};
    final Iterable<RadarPlaybackTimelineEntry> complete = _timelineEntries
        .where((e) => e.isComplete)
        .toList(growable: false)
        .reversed
        .take(maxFrames);
    for (final RadarPlaybackTimelineEntry entry in complete) {
      final RadarPlaybackFrame? f = _frameForTimestamp(entry.timestampUtc);
      if (f == null) continue;
      for (final RadarPlaybackTile t in f.tiles) {
        keys.add(_tileKey(t.minLat, t.minLon, t.maxLat, t.maxLon));
      }
    }
    return keys;
  }

  void _logDisplayedTilesForDebug(String reason) {
    final AppState appState = Provider.of<AppState>(context, listen: false);
    final DateTime? selectedTs = _selectedTimelineTimestamp;
    final RadarPlaybackFrame? frame =
        _isLiveMode ? null : _frameForTimestamp(selectedTs);

    if (!_isLiveMode && frame != null) {
      logger.i(
          'RadarMapDialog: $reason playback frame ts=${_formatTimestamp(selectedTs)} tiles=${frame.tiles.length}');
      for (int i = 0; i < frame.tiles.length; i++) {
        final RadarPlaybackTile t = frame.tiles[i];
        final int pngHash = CRC32.calculate(t.pngBytes);
        final img.Image? decoded = img.decodePng(t.pngBytes);
        int nonTransparent = 0;
        int totalPixels = 0;
        if (decoded != null) {
          totalPixels = decoded.width * decoded.height;
          if (totalPixels > 0) {
            for (int y = 0; y < decoded.height; y++) {
              for (int x = 0; x < decoded.width; x++) {
                final int a = decoded.getPixel(x, y).a.toInt() & 0xFF;
                if (a > 0) nonTransparent++;
              }
            }
          }
        }
        final double coveragePct =
            totalPixels == 0 ? -1.0 : (nonTransparent * 100.0) / totalPixels;
        logger.i(
            'RadarMapDialog: tile[$i] mode=playback bounds=[${t.minLat},${t.minLon}]..[${t.maxLat},${t.maxLon}] '
            'size=${t.width}x${t.height} pngBytes=${t.pngBytes.length} pngHash=0x${pngHash.toRadixString(16).padLeft(8, '0')} '
            'coverage=${coveragePct < 0 ? 'unknown' : '${coveragePct.toStringAsFixed(1)}%'}');
      }
      return;
    }

    final List<RadarOverlay> overlays = appState.radarOverlaysNotifier.value;
    logger.i(
        'RadarMapDialog: $reason live tiles ts=${_formatTimestamp(appState.currentRadarTimestamp)} count=${overlays.length}');
    for (int i = 0; i < overlays.length; i++) {
      final RadarOverlay o = overlays[i];
      final int rgbaHash = CRC32.calculate(o.rgba);
      int nonTransparent = 0;
      final int pixelCount = o.width * o.height;
      for (int p = 3; p < o.rgba.length; p += 4) {
        if ((o.rgba[p] & 0xFF) > 0) nonTransparent++;
      }
      final double coveragePct =
          pixelCount == 0 ? 0.0 : (nonTransparent * 100.0) / pixelCount;
      logger.i(
          'RadarMapDialog: tile[$i] mode=live bounds=[${o.minLat},${o.minLon}]..[${o.maxLat},${o.maxLon}] '
          'size=${o.width}x${o.height} rgbaBytes=${o.rgba.length} rgbaHash=0x${rgbaHash.toRadixString(16).padLeft(8, '0')} '
          'coverage=${coveragePct.toStringAsFixed(1)}%');
    }
  }

  void _togglePlayback() {
    if (_timelineEntries.length < 2) return;
    if (_isPlaying) {
      _logDisplayedTilesForDebug('pause');
      _playTimer?.cancel();
      setState(() {
        _isPlaying = false;
        _isLiveMode = true;
      });
      return;
    }
    setState(() {
      _isPlaying = true;
      _isLiveMode = false;
    });
    _playTimer?.cancel();
    _playTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (!mounted || _timelineEntries.length < 2) return;
      final int next = (_timelineIndex + 1) % _timelineEntries.length;
      unawaited(_selectTimelineIndex(next));
    });
  }

  String _formatTimestamp(DateTime? ts) {
    if (ts == null) return 'Unknown';
    final DateTime local = ts.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _formatTimeShort(DateTime? ts) {
    if (ts == null) return '--:--';
    final DateTime local = ts.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Uint8List _overlayToPng(RadarOverlay o) {
    final cached = _pngCache[o];
    if (cached != null) return cached;

    // Encode raw RGBA to PNG
    final img.Image image = img.Image.fromBytes(
      width: o.width,
      height: o.height,
      bytes: o.rgba.buffer,
      order: img.ChannelOrder.rgba,
    );
    final Uint8List png = Uint8List.fromList(img.encodePng(image));
    _pngCache[o] = png;
    return png;
  }

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context, listen: false);

    final Widget content = SizedBox(
      width: 1120,
      height: 720,
      child: ValueListenableBuilder<List<RadarOverlay>>(
        valueListenable: appState.radarOverlaysNotifier,
        builder: (context, overlays, _) {
          final GraphicalWeatherHandler? handler =
              GraphicalWeatherHandler.activeInstance;
          final DateTime? selectedTs = _selectedTimelineTimestamp;
          final RadarPlaybackFrame? frame =
              _isLiveMode ? null : _frameForTimestamp(selectedTs);
          final DateTime? latestTimestamp = appState.currentRadarTimestamp;
          final RadarPlaybackTimelineEntry? selectedEntry =
              _selectedTimelineEntry;
          final int completeCount =
              _timelineEntries.where((e) => e.isComplete).length;
          final int inProgressCount = _timelineEntries.length - completeCount;
          final RadarPlaybackTimelineEntry? referenceEntry =
              _isLiveMode ? null : _referenceCompleteEntryFor(selectedEntry);
          final RadarPlaybackFrame? referenceFrame = referenceEntry == null
              ? null
              : _frameForTimestamp(referenceEntry.timestampUtc);
          final List<Polygon> missingTilePolygons = <Polygon>[];
          final Set<String> expectedTileKeys = _isLiveMode
              ? <String>{}
              : _expectedTileKeysFromCompleteFrames(maxFrames: 6);
          final Map<String, RadarPlaybackTile> expectedBoundsByKey =
              <String, RadarPlaybackTile>{};
          if (referenceFrame != null) {
            for (final RadarPlaybackTile t in referenceFrame.tiles) {
              expectedBoundsByKey[
                  _tileKey(t.minLat, t.minLon, t.maxLat, t.maxLon)] = t;
            }
          }
          if (!_isLiveMode &&
              selectedEntry != null &&
              !selectedEntry.isComplete &&
              frame != null) {
            final Set<String> present = frame.tiles
                .map((t) => _tileKey(t.minLat, t.minLon, t.maxLat, t.maxLon))
                .toSet();
            final Iterable<String> expectedKeys = expectedTileKeys.isNotEmpty
                ? expectedTileKeys
                : expectedBoundsByKey.keys;
            for (final String key in expectedKeys) {
              if (present.contains(key)) continue;
              final RadarPlaybackTile? t = expectedBoundsByKey[key];
              if (t == null) continue;
              missingTilePolygons.add(
                Polygon(
                  points: <LatLng>[
                    LatLng(t.minLat, t.minLon),
                    LatLng(t.maxLat, t.minLon),
                    LatLng(t.maxLat, t.maxLon),
                    LatLng(t.minLat, t.maxLon),
                  ],
                  color: Colors.black.withValues(alpha: 0.35),
                  borderColor: Colors.amberAccent.withValues(alpha: 0.95),
                  borderStrokeWidth: 2.0,
                ),
              );
            }
          }

          final List<OverlayImage> overlayImages = _isLiveMode
              ? overlays.map((o) {
                  final png = _overlayToPng(o);
                  final LatLngBounds b = LatLngBounds(
                    LatLng(o.minLat, o.minLon),
                    LatLng(o.maxLat, o.maxLon),
                  );
                  return OverlayImage(
                    bounds: b,
                    opacity: 0.7,
                    imageProvider: MemoryImage(png),
                  );
                }).toList(growable: false)
              : frame == null
                  ? <OverlayImage>[]
                  : frame.tiles
                      .map(
                        (t) => OverlayImage(
                          bounds: LatLngBounds(
                            LatLng(t.minLat, t.minLon),
                            LatLng(t.maxLat, t.maxLon),
                          ),
                          opacity: 0.7,
                          imageProvider: MemoryImage(t.pngBytes),
                        ),
                      )
                      .toList(growable: false);

          final List<Polyline> tileBorders = !_isLiveMode
              ? <Polyline>[]
              : overlays.map((o) {
                  final List<LatLng> pts = <LatLng>[
                    LatLng(o.minLat, o.minLon),
                    LatLng(o.maxLat, o.minLon),
                    LatLng(o.maxLat, o.maxLon),
                    LatLng(o.minLat, o.maxLon),
                    LatLng(o.minLat, o.minLon),
                  ];
                  return Polyline(
                    points: pts,
                    strokeWidth: 2.0,
                    color: Colors.cyanAccent.withValues(alpha: 0.9),
                  );
                }).toList(growable: false);
          final int displayedTileCount = overlayImages.length;
          final int expectedTileCount = !_isLiveMode &&
                  selectedEntry != null &&
                  !selectedEntry.isComplete &&
                  expectedTileKeys.isNotEmpty
              ? expectedTileKeys.length
              : displayedTileCount;

          return Stack(
            children: [
              FlutterMap(
                options: const MapOptions(
                  // Always start at a full view
                  initialCenter: LatLng(39.5, -98.35),
                  initialZoom: 4,
                  maxZoom: 13,
                  minZoom: 3.5,
                  backgroundColor: Color.fromARGB(255, 166, 202, 255),
                ),
                children: [
                  ...offlineUsBasemapLayers(),
                  if (overlayImages.isNotEmpty)
                    OverlayImageLayer(overlayImages: overlayImages),
                  if (tileBorders.isNotEmpty)
                    PolylineLayer(polylines: tileBorders),
                  if (missingTilePolygons.isNotEmpty)
                    PolygonLayer(polygons: missingTilePolygons),
                ],
              ),
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Radar Playback • ${_isLiveMode ? 'Live' : 'Playback'}',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: _isPlaying ? 'Pause' : 'Play',
                      onPressed: _togglePlayback,
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.55),
                      ),
                      icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {
                        _playTimer?.cancel();
                        setState(() {
                          _isPlaying = false;
                          _isLiveMode = true;
                        });
                      },
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.55),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Live'),
                    ),
                    if (!widget.embedded) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.black.withValues(alpha: 0.55),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Close'),
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Tilesets: ${_timelineEntries.length}  •  Complete: $completeCount  •  In-progress: $inProgressCount  •  Visible tiles: $displayedTileCount/${expectedTileCount == 0 ? displayedTileCount : expectedTileCount}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                            ),
                          ),
                          Text(
                            'Latest: ${_formatTimeShort(latestTimestamp)}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Cache: ${handler?.cachedPlaybackFrameCount ?? 0}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                          ),
                        ],
                      ),
                      if (_timelineEntries.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Slider(
                                value: _timelineIndex
                                    .clamp(0, _timelineEntries.length - 1)
                                    .toDouble(),
                                min: 0,
                                max: (_timelineEntries.length - 1).toDouble(),
                                divisions: _timelineEntries.length > 1
                                    ? _timelineEntries.length - 1
                                    : null,
                                onChanged: (v) =>
                                    unawaited(_selectTimelineIndex(v.round())),
                              ),
                            ),
                            Text(
                              _isLiveMode
                                  ? 'Live'
                                  : '#${_timelineIndex + 1} ${_formatTimeShort(selectedTs)}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                            ),
                            if (!_isLiveMode &&
                                selectedEntry != null &&
                                !selectedEntry.isComplete) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.0,
                                  value: selectedEntry.progress,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${selectedEntry.tileCount}/${selectedEntry.inferredCompleteTileCount}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Missing: ${missingTilePolygons.length}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    if (widget.embedded) {
      return content;
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: content,
    );
  }
}
