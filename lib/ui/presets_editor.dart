// Presets Editor Dialog, allows the user to edit the presets
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/main.dart';
import 'package:orbit/ui/preset.dart';

class PresetsEditorDialog extends StatefulWidget {
  final AppState appState;
  final MainPageState mainPage;

  const PresetsEditorDialog({
    super.key,
    required this.appState,
    required this.mainPage,
  });

  @override
  State<PresetsEditorDialog> createState() => _PresetsEditorDialogState();
}

class _PresetsEditorDialogState extends State<PresetsEditorDialog> {
  late List<Preset> _workingPresets;
  late List<int> _originalSids;
  final Map<int, Uint8List> _logoCache = {};

  @override
  void initState() {
    super.initState();
    _workingPresets = widget.appState.presets
        .map((p) => Preset(
              sid: p.sid,
              channelNumber: p.channelNumber,
              channelName: p.channelName,
              song: p.song,
              artist: p.artist,
            ))
        .toList(growable: true);
    _ensureLength();
    _originalSids = _workingPresets.map((p) => p.sid).toList(growable: false);
  }

  void _ensureLength() {
    // Ensure we always have exactly 18 slots
    const int desired = 18;
    if (_workingPresets.length < desired) {
      _workingPresets.addAll(
        List.generate(desired - _workingPresets.length, (_) => Preset()),
      );
    } else if (_workingPresets.length > desired) {
      _workingPresets = _workingPresets.sublist(0, desired);
    }
  }

  bool _hasChanges() {
    final List<int> current = _workingPresets.map((p) => p.sid).toList();
    return !listEquals(current, _originalSids);
  }

  Future<bool> _confirmDiscardIfNeeded() async {
    if (!_hasChanges()) return true;
    final theme = Theme.of(context);
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text(
            'You have unsaved changes to your presets. Do you want to discard them?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return confirm ?? false;
  }

  void _saveAndClose() {
    // Update AppState presets, maintain all 18 entries
    _ensureLength();
    for (int i = 0; i < widget.appState.presets.length; i++) {
      widget.appState.presets[i] = _workingPresets[i];
    }
    // Notify and send to device
    try {
      // Trigger provider rebuilds
      widget.appState.updateNowPlaying();
    } catch (_) {}

    widget.mainPage.sendPresets();
    Navigator.of(context).pop(true);
  }

  void _clearAt(int index) {
    setState(() {
      _workingPresets[index] = Preset();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_hasChanges(),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final bool shouldPop = await _confirmDiscardIfNeeded();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop(false);
        }
      },
      child: AlertDialog(
        title: Row(
          children: [
            const Expanded(
              child: Text(
                'Edit Presets',
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
            TextButton(
              onPressed: _saveAndClose,
              child: const Text('Save'),
            ),
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.close),
              onPressed: () async {
                if (await _confirmDiscardIfNeeded()) {
                  if (context.mounted) Navigator.of(context).pop(false);
                }
              },
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: 600,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Reorder or delete presets. Drag to reorder. Deleting clears the slot.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _workingPresets.length,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final item = _workingPresets.removeAt(oldIndex);
                      _workingPresets.insert(newIndex, item);
                    });
                  },
                  itemBuilder: (context, index) {
                    final preset = _workingPresets[index];
                    final isEmpty = preset.sid == 0;
                    final List<int> rawLogo = isEmpty
                        ? const []
                        : widget.appState.storageData
                            .getImageForSid(preset.sid);
                    final Uint8List? logoBytes = rawLogo.isEmpty
                        ? null
                        : (_logoCache[preset.sid] ??=
                            Uint8List.fromList(rawLogo));

                    Widget leading = _numberBadge(theme, index);

                    return ListTile(
                      key: ObjectKey(preset),
                      leading: leading,
                      title: Text(
                        isEmpty ? 'Empty' : preset.channelName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isEmpty
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: isEmpty
                          ? null
                          : Text(
                              'Ch. ${preset.channelNumber} • ${preset.artist} — ${preset.song}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (logoBytes != null)
                            SizedBox(
                              width: 56,
                              height: 36,
                              child: Image.memory(
                                logoBytes,
                                cacheHeight: 128,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                                errorBuilder: (_, __, ___) {
                                  return const SizedBox.shrink();
                                },
                              ),
                            ),
                          if (logoBytes != null && !isEmpty)
                            const SizedBox(width: 8),
                          if (!isEmpty)
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _clearAt(index),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _numberBadge(ThemeData theme, int index) {
    return CircleAvatar(
      radius: 14,
      backgroundColor: theme.colorScheme.primaryContainer,
      child: Text(
        '${index + 1}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class PresetsEditorDialogHelper {
  static Future<bool> show(
      {required BuildContext context,
      required AppState appState,
      required MainPageState mainPage}) async {
    final bool? saved = await showDialog<bool>(
      barrierDismissible: true,
      context: context,
      builder: (context) => PresetsEditorDialog(
        appState: appState,
        mainPage: mainPage,
      ),
    );
    return saved == true;
  }
}
