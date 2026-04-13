import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';

/// First-run only: shown when [AppState.welcomeSeen] is false and the display
/// heuristic suggests compact / automotive layouts, so the user can opt in
/// to Small Screen Mode instead of having it applied automatically.
class SmallScreenModeConfirmDialog extends StatelessWidget {
  final AppState appState;

  const SmallScreenModeConfirmDialog({super.key, required this.appState});

  static Future<void> show(BuildContext context, AppState appState) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          SmallScreenModeConfirmDialog(appState: appState),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return AlertDialog(
      title: const Text('Small Screen Mode'),
      content: SizedBox(
        width: 400,
        child: Text(
          'This display looks compact. Small Screen Mode uses larger touch '
          'targets and a simplified layout. Do you want to use it?',
          style: TextStyle(fontSize: 16, color: onSurface),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            appState.updateSmallScreenMode(false);
            Navigator.of(context).pop();
          },
          child: const Text('Standard layout'),
        ),
        FilledButton(
          onPressed: () {
            appState.updateSmallScreenMode(true);
            Navigator.of(context).pop();
          },
          child: const Text('Use Small Screen Mode'),
        ),
      ],
    );
  }
}
