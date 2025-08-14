// Signal Quality Dialog, shows the signal quality
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../helpers.dart';
import '../sxi_command_types.dart';
import '../sxi_commands.dart';
import '../device_layer.dart';
import 'signal_bar.dart';

class SignalQualityDialog extends StatefulWidget {
  final DeviceLayer deviceLayer;

  const SignalQualityDialog({super.key, required this.deviceLayer});

  @override
  State<SignalQualityDialog> createState() => _SignalQualityDialogState();
}

class _SignalQualityDialogState extends State<SignalQualityDialog> {
  @override
  void initState() {
    super.initState();
    _enableSignalMonitoring();
  }

  @override
  void dispose() {
    _disableSignalMonitoring();
    super.dispose();
  }

  void _enableSignalMonitoring() {
    // Tell the device to start monitoring the signal quality
    final cfgCmd = SXiMonitorStatusCommand(
      MonitorChangeType.monitor,
      [
        StatusMonitorType.signalQuality,
        StatusMonitorType.overlaySignalQuality,
      ],
    );
    widget.deviceLayer.sendControlCommand(cfgCmd);
  }

  void _disableSignalMonitoring() {
    // Tell the device to stop monitoring the signal quality
    final cfgCmd = SXiMonitorStatusCommand(
      MonitorChangeType.dontMonitor,
      [
        StatusMonitorType.signalQuality,
        StatusMonitorType.overlaySignalQuality,
      ],
    );
    widget.deviceLayer.sendControlCommand(cfgCmd);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<AppState>(
      builder: (context, appState, child) {
        return AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    getSignalIcon(appState.signalQuality,
                        isAntennaConnected: appState.isAntennaConnected),
                    color: _getSignalColor(appState.signalQuality, theme),
                  ),
                  const SizedBox(width: 8),
                  const Text('Signal Quality'),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildBasicSignalInfo(appState, theme),
                  const SizedBox(height: 8),
                  _buildBaseSignalQuality(appState, theme),
                  const SizedBox(height: 8),
                  _buildOverlaySignalQuality(appState, theme),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBasicSignalInfo(AppState appState, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Signal Status',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  flex: 3,
                  child: Text(
                    'Signal Level:',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FractionallySizedBox(
                      widthFactor: 0.5,
                      alignment: Alignment.centerRight,
                      child: SignalBar(
                        level: appState.signalQuality,
                        maxLevel: 4,
                        isAntennaConnected: appState.isAntennaConnected,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            _buildInfoRow(
              'Antenna:',
              appState.isAntennaConnected ? 'Connected' : 'Not Connected',
              valueColor: appState.isAntennaConnected
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.error,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBaseSignalQuality(AppState appState, ThemeData theme) {
    final baseSignal = appState.baseSignalQuality;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Base Layer Signal Quality',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 6),
            if (baseSignal != null) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    flex: 3,
                    child: Text(
                      'Signal Strength:',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FractionallySizedBox(
                        widthFactor: 0.5,
                        alignment: Alignment.centerRight,
                        child: SignalBar(
                          level: baseSignal.signalStrength,
                          maxLevel: 4,
                          isAntennaConnected: appState.isAntennaConnected,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              _buildInfoRow('Tuner Status:', baseSignal.tunerStatusFlags),
              _buildInfoRow(
                  'ENSA Lock Status:', baseSignal.ensALockStatusFlags),
              _buildInfoRow(
                  'ENSB Lock Status:', baseSignal.ensBLockStatusFlags),
              const Divider(height: 12),
              Text(
                'Base Layer Bit Error Rates',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 4),
              _buildInfoRow('SAT1 BER:', baseSignal.berS1Percent),
              _buildInfoRow('SAT2 BER:', baseSignal.berS2Percent),
              _buildInfoRow('TERR BER:', baseSignal.berTPercent),
            ] else
              Text(
                'No base signal quality data available.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlaySignalQuality(AppState appState, ThemeData theme) {
    final overlaySignal = appState.overlaySignalQualityData;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Overlay Layer Signal Quality',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 6),
            if (overlaySignal != null) ...[
              _buildInfoRow(
                  'Overlay Receiver Status:', overlaySignal.receiverStateFlags),
              const Divider(height: 12),
              Text(
                'Overlay Layer Bit Error Rates',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 4),
              _buildInfoRow('SAT 1A BER:', overlaySignal.oberS1APercent),
              _buildInfoRow('SAT 2A BER:', overlaySignal.oberS2APercent),
              _buildInfoRow('TERR BER:', overlaySignal.oberTAPercent),
              _buildInfoRow('SAT 1B BER:', overlaySignal.oberS1BPercent),
              _buildInfoRow('SAT 2B BER:', overlaySignal.oberS2BPercent),
              _buildInfoRow('OTB BER:', overlaySignal.oberTBPercent),
            ] else
              Text(
                'No overlay signal quality data available.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getSignalColor(int signalQuality, ThemeData theme) {
    if (signalQuality >= 3) {
      return theme.colorScheme.primary;
    } else if (signalQuality >= 1) {
      return theme.colorScheme.tertiary;
    } else {
      return theme.colorScheme.error;
    }
  }
}
