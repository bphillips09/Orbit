import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit/logging.dart';
import 'package:universal_io/io.dart';

class LogViewerPage extends StatelessWidget {
  const LogViewerPage({
    super.key,
    this.title = 'Application Log',
  });

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const LogViewer(),
    );
  }
}

class LogViewer extends StatefulWidget {
  const LogViewer({
    super.key,
    this.compact = false,
  });

  final bool compact;

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  static const int _maxUiLines = 4000;
  static const int _fileTailBytes = 256 * 1024;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  StreamSubscription<List<String>>? _sub;
  final List<String> _lines = <String>[];

  bool _follow = true;
  bool _paused = false;
  bool _caseSensitive = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _lines.addAll(AppLogger.instance.recentLines);
    _sub = AppLogger.instance.lineStream.listen((incoming) {
      if (_paused) return;
      if (incoming.isEmpty) return;
      setState(() {
        _appendLines(incoming);
      });
      _maybeFollow();
    });
    _searchController.addListener(() {
      setState(() {
        // Rebuild with new filter
      });
      _maybeFollow();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _appendLines(List<String> incoming) {
    _lines.addAll(incoming);
    if (_lines.length > _maxUiLines) {
      _lines.removeRange(0, _lines.length - _maxUiLines);
    }
  }

  List<String> _filteredLines() {
    final q = _searchController.text.trim();
    if (q.isEmpty) return List<String>.unmodifiable(_lines);

    if (_caseSensitive) {
      return _lines.where((l) => l.contains(q)).toList(growable: false);
    }

    final needle = q.toLowerCase();
    return _lines
        .where((l) => l.toLowerCase().contains(needle))
        .toList(growable: false);
  }

  void _maybeFollow() {
    if (!_follow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollController.hasClients) return;
      try {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      } catch (_) {
        // Ignore scroll errors when not laid out yet
      }
    });
  }

  Future<void> _reloadFromFileTail() async {
    if (kIsWeb || kIsWasm) {
      setState(() {
        _status = 'File logs unavailable on web.';
      });
      return;
    }

    setState(() {
      _status = 'Loading from log file...';
    });

    try {
      await AppLogger.instance.ensureFileOutputReady();
      final path = AppLogger.instance.logFilePath;
      if (path == null) {
        setState(() {
          _status = 'Log file path unavailable.';
        });
        return;
      }

      final file = File(path);
      if (!await file.exists()) {
        setState(() {
          _status = 'Log file not found.';
        });
        return;
      }

      final int length = await file.length();
      final int start = length > _fileTailBytes ? (length - _fileTailBytes) : 0;
      final String content =
          await file.openRead(start).transform(utf8.decoder).join();
      final nextLines = const LineSplitter().convert(content);

      if (!mounted) return;
      setState(() {
        _lines
          ..clear()
          ..addAll(nextLines);
        _status = 'Loaded ${nextLines.length} lines from file.';
      });
      _maybeFollow();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'Failed to read log file: $e';
      });
    }
  }

  Future<void> _copyFilteredToClipboard() async {
    final text = _filteredLines().join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() {
      _status = 'Copied ${text.length} chars to clipboard.';
    });
  }

  void _clear() {
    setState(() {
      _lines.clear();
      _status = 'Cleared.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filteredLines();

    final bool isCompact = widget.compact;
    final double fontSize = isCompact ? 11.0 : 12.5;

    final TextStyle logStyle = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(fontFamily: 'monospace', fontSize: fontSize, height: 1.25);

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              isCompact ? 8 : 12, 8, isCompact ? 8 : 12, isCompact ? 6 : 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: 'Filter logs',
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear filter',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => _searchController.clear(),
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _caseSensitive ? 'Case-sensitive' : 'Case-insensitive',
                icon: Icon(
                  _caseSensitive
                      ? Icons.text_fields
                      : Icons.text_fields_outlined,
                ),
                onPressed: () {
                  setState(() {
                    _caseSensitive = !_caseSensitive;
                  });
                },
              ),
              IconButton(
                tooltip: _paused ? 'Resume updates' : 'Pause updates',
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                onPressed: () {
                  setState(() {
                    _paused = !_paused;
                    _status = _paused ? 'Paused.' : 'Resumed.';
                  });
                },
              ),
              IconButton(
                tooltip: _follow ? 'Disable follow tail' : 'Follow tail',
                icon: Icon(
                    _follow ? Icons.vertical_align_bottom : Icons.unfold_more),
                onPressed: () {
                  setState(() {
                    _follow = !_follow;
                    _status = _follow ? 'Follow enabled.' : 'Follow disabled.';
                  });
                  _maybeFollow();
                },
              ),
              if (!isCompact)
                IconButton(
                  tooltip: 'Reload from file tail',
                  icon: const Icon(Icons.refresh),
                  onPressed: _reloadFromFileTail,
                ),
              IconButton(
                tooltip: 'Copy filtered',
                icon: const Icon(Icons.copy),
                onPressed: _copyFilteredToClipboard,
              ),
              IconButton(
                tooltip: 'Clear view',
                icon: const Icon(Icons.delete_sweep),
                onPressed: _clear,
              ),
            ],
          ),
        ),
        if (_status.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
                isCompact ? 8 : 12, 0, isCompact ? 8 : 12, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        Expanded(
          child: Container(
            margin: EdgeInsets.fromLTRB(
                isCompact ? 8 : 12, 0, isCompact ? 8 : 12, isCompact ? 8 : 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.dividerColor),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(10),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return ConstrainedBox(
                        constraints: BoxConstraints.tightFor(
                          width: constraints.maxWidth,
                        ),
                        child: SelectableText(
                          filtered.isEmpty
                              ? 'No log output yet.'
                              : filtered.join('\n'),
                          style: logStyle,
                          textAlign: TextAlign.left,
                          textWidthBasis: TextWidthBasis.parent,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
