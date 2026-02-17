import 'package:flutter/material.dart';
import 'package:orbit/ui/log_viewer.dart';

class LogOverlayHost extends StatefulWidget {
  const LogOverlayHost({
    super.key,
    required this.child,
    required this.enabled,
  });

  final Widget child;
  final bool enabled;

  @override
  State<LogOverlayHost> createState() => _LogOverlayHostState();
}

class _LogOverlayHostState extends State<LogOverlayHost> {
  bool _panelVisible = false;

  Offset _offset = const Offset(24, 90);
  Size _size = const Size(560, 320);

  @override
  void didUpdateWidget(covariant LogOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _panelVisible) {
      _panelVisible = false;
    }
  }

  Offset _clampOffset(Offset proposed, Size panelSize, Size screen) {
    const double minMargin = 8;
    const double minVisibleGripWidth = 56;
    final double maxX = (screen.width - panelSize.width - minMargin);
    final double maxY = (screen.height - panelSize.height - minMargin);
    return Offset(
      proposed.dx.clamp(
        -panelSize.width + minVisibleGripWidth,
        maxX < minMargin ? minMargin : maxX,
      ),
      proposed.dy.clamp(minMargin, maxY < minMargin ? minMargin : maxY),
    );
  }

  Size _clampSize(Size proposed, Size screen) {
    const double minW = 320;
    const double minH = 180;
    final double maxW = (screen.width - 16).clamp(minW, screen.width);
    final double maxH = (screen.height - 16).clamp(minH, screen.height);
    return Size(
      proposed.width.clamp(minW, maxW),
      proposed.height.clamp(minH, maxH),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screen = mq.size;
    _size = _clampSize(_size, screen);
    _offset = _clampOffset(_offset, _size, screen);

    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (_) {
            return Stack(
              children: [
                widget.child,
                if (widget.enabled) ...[
                  Positioned(
                    right: 12,
                    bottom: 12 + mq.padding.bottom,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: _panelVisible
                          ? const SizedBox.shrink()
                          : FloatingActionButton.small(
                              key: const ValueKey<String>('log_overlay_button'),
                              tooltip: 'Show log overlay',
                              onPressed: () {
                                setState(() {
                                  _panelVisible = true;
                                });
                              },
                              child: const Icon(Icons.article_outlined),
                            ),
                    ),
                  ),
                  if (_panelVisible)
                    Positioned(
                      left: _offset.dx,
                      top: _offset.dy,
                      width: _size.width,
                      height: _size.height,
                      child: _OverlayPanel(
                        onClose: () {
                          setState(() {
                            _panelVisible = false;
                          });
                        },
                        onDragDelta: (delta) {
                          setState(() {
                            _offset =
                                _clampOffset(_offset + delta, _size, screen);
                          });
                        },
                        onResizeDelta: (delta) {
                          setState(() {
                            _size = _clampSize(
                              Size(
                                _size.width + delta.dx,
                                _size.height + delta.dy,
                              ),
                              screen,
                            );
                            _offset = _clampOffset(_offset, _size, screen);
                          });
                        },
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _OverlayPanel extends StatelessWidget {
  const _OverlayPanel({
    required this.onClose,
    required this.onDragDelta,
    required this.onResizeDelta,
  });

  final VoidCallback onClose;
  final ValueChanged<Offset> onDragDelta;
  final ValueChanged<Offset> onResizeDelta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      elevation: 10,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => onDragDelta(d.delta),
                  child: Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Row(
                      children: [
                        const Icon(Icons.drag_handle),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Logs',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close overlay',
                          icon: const Icon(Icons.close),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                ),
                const Expanded(child: LogViewer(compact: true)),
              ],
            ),
            Positioned(
              right: 2,
              bottom: 2,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => onResizeDelta(d.delta),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.drag_indicator,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
