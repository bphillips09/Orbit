import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';
import 'package:orbit/app_state.dart';

/// Order used in log level menus and the settings dialog.
const List<Level> kLogLevelMenuOrder = <Level>[
  Level.trace,
  Level.debug,
  Level.info,
  Level.warning,
  Level.error,
  Level.fatal,
  Level.off,
];

String logLevelDisplayName(Level level) {
  switch (level) {
    case Level.trace:
      return 'Trace';
    case Level.debug:
      return 'Debug';
    case Level.info:
      return 'Info';
    case Level.warning:
      return 'Warning';
    case Level.error:
      return 'Error';
    case Level.fatal:
      return 'Fatal';
    case Level.off:
      return 'Off';
    default:
      return level.name;
  }
}

/// Same choices as Settings → Debug → Logging → Log Level; persists via [AppState].
Future<void> showLogLevelPickerDialog(
  BuildContext context, {
  bool showConfirmationSnackBar = true,
}) async {
  final appState = Provider.of<AppState>(context, listen: false);
  final theme = Theme.of(context);

  final Level? selected = await showDialog<Level>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        title: const Text('Select Log Level'),
        content: SizedBox(
          width: 360,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: kLogLevelMenuOrder.length,
            itemBuilder: (BuildContext listContext, int index) {
              final level = kLogLevelMenuOrder[index];
              final isSelected = appState.logLevel == level;
              return ListTile(
                leading: Icon(
                  isSelected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
                title: Text(logLevelDisplayName(level)),
                onTap: () => Navigator.pop(listContext, level),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );

  if (selected != null) {
    appState.updateLogLevel(selected);
    if (showConfirmationSnackBar && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Log level set to ${logLevelDisplayName(selected)}'),
        ),
      );
    }
  }
}

/// Tune icon; opens the same dialog as Settings → Log Level.
/// Requires [Provider<AppState>] above for the tooltip label.
class LogLevelPopupMenuButton extends StatelessWidget {
  const LogLevelPopupMenuButton({super.key, this.dense = false});

  /// Slightly smaller icon in the compact floating log toolbar.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, Level>(
      selector: (_, AppState s) => s.logLevel,
      builder: (BuildContext context, Level currentLevel, Widget? _) {
        return IconButton(
          tooltip: 'Log level: ${logLevelDisplayName(currentLevel)}',
          icon: Icon(
            Icons.tune,
            size: dense ? 20 : 24,
          ),
          onPressed: () => showLogLevelPickerDialog(context),
        );
      },
    );
  }
}
