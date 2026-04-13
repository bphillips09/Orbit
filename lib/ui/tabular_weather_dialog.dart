// Tabular Weather UI
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:orbit/data/weather/forecast_parser.dart';
import 'package:orbit/data/weather/tabular_weather_state.dart';
import 'package:orbit/data/weather/tabular_weather_event_codes.dart';
import 'package:orbit/data/weather/tabular_weather_location.dart';
import 'package:orbit/platform/download_bytes.dart';
import 'package:universal_io/io.dart';

class TabularWeatherDialog extends StatefulWidget {
  final TabularWeatherState tabularWeatherState;
  final bool embedded;

  const TabularWeatherDialog({
    super.key,
    required this.tabularWeatherState,
    this.embedded = false,
  });

  @override
  State<TabularWeatherDialog> createState() => _TabularWeatherDialogState();
}

class _TabularWeatherDialogState extends State<TabularWeatherDialog> {
  final TextEditingController _controller = TextEditingController();
  List<TabularWeatherLocation> _results = const <TabularWeatherLocation>[];

  Future<void> _saveDbToFile(BuildContext context) async {
    final Uint8List? bytes = widget.tabularWeatherState.tabularWeatherDbBytes;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No database cached yet.')),
      );
      return;
    }

    final String base = widget.tabularWeatherState.tabularWeatherDbFileName ??
        'tabular_weather_db';
    final String suggestedName =
        base.toLowerCase().endsWith('.bin') ? base : '$base.bin';

    if (kIsWeb) {
      downloadBytes(bytes,
          filename: suggestedName, mimeType: 'application/octet-stream');
      return;
    }

    final String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save database',
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: const ['bin'],
      bytes: bytes,
    );
    if (savePath == null || savePath.trim().isEmpty) return;

    final String outPath = savePath.trim();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved database to $outPath')),
      );
    }
  }

  Future<void> _loadDbFromFile(BuildContext context) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['bin'],
      withData: kIsWeb || Platform.isAndroid,
    );
    if (result == null || result.files.isEmpty) return;
    final PlatformFile f = result.files.first;

    Uint8List? bytes = f.bytes;
    if (bytes == null) {
      final String? path = f.path;
      if (path == null || path.isEmpty) return;
      bytes = await File(path).readAsBytes();
    }
    if (bytes.isEmpty) return;

    widget.tabularWeatherState
        .updateTabularWeatherDatabaseBytes(bytes, fileName: f.name);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded database (${bytes.length} bytes)')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final String q = _controller.text;
    final List<TabularWeatherLocation> next =
        widget.tabularWeatherState.searchTabularWeatherLocations(q, limit: 50);
    if (mounted) {
      setState(() {
        _results = next;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.tabularWeatherState,
      builder: (context, _) {
        final bool hasDb = widget.tabularWeatherState.hasTabularWeatherDb;
        final TabularWeatherLocation? selected =
            widget.tabularWeatherState.tabularWeatherSelectedLocation;
        final Map<int, ForecastRecord?> byType =
            widget.tabularWeatherState.tabularWeatherForecastByType;
        final String query = _controller.text.trim();
        final bool isSearching = query.isNotEmpty;
        final List<TabularWeatherLocation> listToShow = isSearching
            ? _results
            : widget.tabularWeatherState.tabularWeatherLocationsWithData();

        final Widget locationList = listToShow.isEmpty
            ? Center(
                child: Text(
                  isSearching
                      ? 'No matches'
                      : (hasDb
                          ? 'No locations with data in database'
                          : 'Database not yet loaded'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              )
            : ListView.separated(
                itemCount: listToShow.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, idx) {
                  final TabularWeatherLocation loc = listToShow[idx];
                  return ListTile(
                    dense: true,
                    title: Text(loc.displayName.isEmpty
                        ? '(unknown)'
                        : loc.displayName),
                    subtitle: Text(
                      'Station ID: ${loc.stationId.isEmpty ? '(none)' : loc.stationId}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => widget.tabularWeatherState
                        .selectTabularWeatherLocation(loc),
                  );
                },
              );

        final Widget content = LayoutBuilder(
          builder: (context, constraints) {
            final bool hasBoundedHeight = constraints.maxHeight.isFinite;
            final Widget resultsSection = hasBoundedHeight
                ? Expanded(child: locationList)
                : SizedBox(height: 320, child: locationList);

            return SizedBox(
              width: widget.embedded ? double.infinity : 640,
              child: Column(
                mainAxisSize:
                    hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        hasDb ? Icons.check_circle : Icons.hourglass_empty,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          hasDb
                              ? 'Location database loaded (${widget.tabularWeatherState.tabularWeatherLocationCount} entries)'
                              : 'Waiting for weather location database...',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Recompute forecasts',
                        onPressed: selected == null
                            ? null
                            : () => widget.tabularWeatherState
                                .recomputeTabularWeatherForecasts(),
                        icon: const Icon(Icons.refresh),
                      ),
                      IconButton(
                        tooltip: 'Re-parse last database',
                        onPressed: widget
                                .tabularWeatherState.canReparseTabularWeatherDb
                            ? () => widget.tabularWeatherState
                                .reparseLastTabularWeatherDatabase()
                            : null,
                        icon: const Icon(Icons.replay),
                      ),
                      IconButton(
                        tooltip: 'Save database to file',
                        onPressed: widget
                                .tabularWeatherState.canReparseTabularWeatherDb
                            ? () => _saveDbToFile(context)
                            : null,
                        icon: const Icon(Icons.save_alt),
                      ),
                      IconButton(
                        tooltip: 'Load database from file',
                        onPressed: () => _loadDbFromFile(context),
                        icon: const Icon(Icons.folder_open),
                      ),
                    ],
                  ),
                  if (!hasDb &&
                      widget.tabularWeatherState
                          .tabularWeatherDbDownloadInProgress) ...[
                    const SizedBox(height: 8),
                    widget.tabularWeatherState.tabularWeatherDbReceivedBytes > 0
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Receiving weather database: '
                              '${widget.tabularWeatherState.tabularWeatherDbReceivedBytes}'
                              '${widget.tabularWeatherState.tabularWeatherDbExpectedBytes != null ? '/${widget.tabularWeatherState.tabularWeatherDbExpectedBytes}' : ''} bytes',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          )
                        : const SizedBox.shrink(),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: (widget.tabularWeatherState
                                      .tabularWeatherDbExpectedBytes !=
                                  null &&
                              widget.tabularWeatherState
                                      .tabularWeatherDbExpectedBytes! >
                                  0)
                          ? (widget.tabularWeatherState
                                      .tabularWeatherDbReceivedBytes /
                                  widget.tabularWeatherState
                                      .tabularWeatherDbExpectedBytes!)
                              .clamp(0.0, 1.0)
                          : null,
                    ),
                  ],
                  if (widget.tabularWeatherState.tabularWeatherLastDbUpdate !=
                      null) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Database updated: ${widget.tabularWeatherState.tabularWeatherLastDbUpdate}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                  if (hasDb) ...[
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Database bytes cached: ${widget.tabularWeatherState.tabularWeatherDbBytesLength}  file: ${widget.tabularWeatherState.tabularWeatherDbFileName ?? '(unknown)'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: 'Name or Station ID',
                      hintText: 'e.g. KHOU or Houston',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (selected != null) ...[
                    _SelectedLocationCard(
                      location: selected,
                      byType: byType,
                      onClear: () => widget.tabularWeatherState
                          .selectTabularWeatherLocation(null),
                    ),
                    const SizedBox(height: 12),
                  ],
                  resultsSection,
                ],
              ),
            );
          },
        );
        return Padding(
          padding: const EdgeInsets.all(12),
          child: content,
        );
      },
    );
  }
}

class _SelectedLocationCard extends StatelessWidget {
  final TabularWeatherLocation location;
  final Map<int, ForecastRecord?> byType;
  final VoidCallback onClear;

  const _SelectedLocationCard({
    required this.location,
    required this.byType,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    const List<_ForecastSlot> slots = <_ForecastSlot>[
      _ForecastSlot(
          forecastType: 0,
          label: 'Current',
          tempMode: _TempDisplayMode.currentOnly),
      _ForecastSlot(
          forecastType: 1,
          label: '3 Hour',
          tempMode: _TempDisplayMode.currentOnly),
      _ForecastSlot(
          forecastType: 2,
          label: '36 Hour',
          tempMode: _TempDisplayMode.currentOnly),
      _ForecastSlot(
          forecastType: 4, label: 'Monday', tempMode: _TempDisplayMode.minMax),
      _ForecastSlot(
          forecastType: 5, label: 'Tuesday', tempMode: _TempDisplayMode.minMax),
      _ForecastSlot(
          forecastType: 6,
          label: 'Wednesday',
          tempMode: _TempDisplayMode.minMax),
      _ForecastSlot(
          forecastType: 7,
          label: 'Thursday',
          tempMode: _TempDisplayMode.minMax),
      _ForecastSlot(
          forecastType: 8, label: 'Friday', tempMode: _TempDisplayMode.minMax),
      _ForecastSlot(
          forecastType: 9,
          label: 'Saturday',
          tempMode: _TempDisplayMode.minMax),
      _ForecastSlot(
          forecastType: 3, label: 'Sunday', tempMode: _TempDisplayMode.minMax),
    ];

    String fmtTemp(double? v) {
      if (v == null) return '-';
      final String s = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
      return '$s°F';
    }

    IconData? iconForEvent(String? label) {
      if (label == null || label.isEmpty) return null;
      final String l = label.toLowerCase();
      if (l.contains('thunder') ||
          l.contains('tornado') ||
          l.contains('hurricane') ||
          l.contains('tropical storm')) {
        return Icons.thunderstorm;
      }
      if (l.contains('snow') ||
          l.contains('sleet') ||
          l.contains('ice') ||
          l.contains('flurr')) {
        return Icons.ac_unit;
      }
      if (l.contains('rain') ||
          l.contains('shower') ||
          l.contains('drizzle') ||
          l.contains('hail') ||
          l.contains('wintry mix')) {
        return Icons.grain;
      }
      if (l.contains('fog') ||
          l.contains('mist') ||
          l.contains('hazy') ||
          l.contains('smoke') ||
          l.contains('dust') ||
          l.contains('sand')) {
        return Icons.foggy;
      }
      if (l.contains('sunny') || l.contains('clear') || l.contains('hot')) {
        return Icons.wb_sunny;
      }
      if (l.contains('cloud')) {
        return Icons.cloud;
      }
      if (l.contains('wind') || l.contains('blustery')) {
        return Icons.air;
      }
      if (l.contains('cold')) {
        return Icons.thermostat;
      }
      return null;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${location.displayName}${location.stationId.isNotEmpty ? ' (${location.stationId})' : ''}',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: onClear,
                  icon: const Icon(Icons.close),
                  label: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${location.latDeg.toStringAsFixed(4)}, ${location.lonDeg.toStringAsFixed(4)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (byType.isEmpty)
              Text(
                'No forecast downloaded yet',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else
              SizedBox(
                height: 220,
                child: ListView.separated(
                  itemCount: slots.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final _ForecastSlot slot = slots[i];
                    final ForecastRecord? r = byType[slot.forecastType];
                    final String? eventLabel = r == null
                        ? null
                        : tabularWeatherEventLabel(r.eventCode);
                    final String eventText = r == null
                        ? 'No data'
                        : (eventLabel ?? 'Event ${r.eventCode}');
                    final String tempText = switch (slot.tempMode) {
                      _TempDisplayMode.currentOnly =>
                        'Current: ${fmtTemp(r?.tempCurF)}',
                      _TempDisplayMode.minMax =>
                        'Min: ${fmtTemp(r?.tempMinF)}  Max: ${fmtTemp(r?.tempMaxF)}',
                    };
                    final IconData? eventIcon = iconForEvent(eventLabel);

                    return ListTile(
                      dense: true,
                      titleAlignment: ListTileTitleAlignment.center,
                      title: Text(slot.label),
                      subtitle: Text('$eventText\n$tempText'),
                      isThreeLine: true,
                      trailing: eventIcon != null
                          ? Icon(
                              eventIcon,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _TempDisplayMode {
  currentOnly,
  minMax,
}

class _ForecastSlot {
  final int forecastType;
  final String label;
  final _TempDisplayMode tempMode;

  const _ForecastSlot({
    required this.forecastType,
    required this.label,
    required this.tempMode,
  });
}
