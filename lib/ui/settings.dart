// Settings Page
import 'dart:io';
import 'dart:math';
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:orbit/data/handlers/channel_graphics_handler.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:orbit/ui/connection_dialogs.dart';
import 'package:orbit/ui/epg_schedule_view.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/main.dart';
import 'package:orbit/storage/storage_data.dart';
import 'package:orbit/ui/presets_editor.dart';
import 'package:orbit/ui/favorites_manager.dart';
import 'package:orbit/ui/favorites_on_air_dialog.dart';
import 'package:orbit/ui/signal_bar.dart';
import 'package:orbit/ui/streaming_beta.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/logging.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';

class SettingsPage extends StatelessWidget {
  final MainPageState mainPage;
  static final Map<String, GlobalKey<_CollapsibleSectionState>> _sectionKeys = {
    'Radio': GlobalKey<_CollapsibleSectionState>(),
    'Appearance': GlobalKey<_CollapsibleSectionState>(),
    'Connection': GlobalKey<_CollapsibleSectionState>(),
    'Hardware Equalizer': GlobalKey<_CollapsibleSectionState>(),
    'Audio': GlobalKey<_CollapsibleSectionState>(),
    'System Info': GlobalKey<_CollapsibleSectionState>(),
    'Data': GlobalKey<_CollapsibleSectionState>(),
    'Logging': GlobalKey<_CollapsibleSectionState>(),
    'Debug': GlobalKey<_CollapsibleSectionState>(),
  };
  const SettingsPage({super.key, required this.mainPage});

  @override
  Widget build(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    final theme = Theme.of(context);
    const sectionSpacing = 16.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        elevation: 0,
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.onSurface,
        actions: [
          IconButton(
            tooltip: 'Expand/Collapse All',
            icon: const Icon(Icons.unfold_more),
            onPressed: () {
              final states = _sectionKeys.values
                  .map((k) => k.currentState)
                  .whereType<_CollapsibleSectionState>()
                  .toList();
              if (states.isEmpty) return;
              final anyCollapsed = states.any((s) => !s.isExpanded);
              final newState =
                  anyCollapsed; // Expand if any collapsed, else collapse
              for (final s in states) {
                s.setExpanded(newState);
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSection(
              context,
              'Radio',
              Icons.radio,
              [
                _buildSettingTile(
                  context,
                  'Presets',
                  'Edit, reorder, or delete presets',
                  Icons.star,
                  onTap: () async {
                    final appState =
                        Provider.of<AppState>(context, listen: false);
                    final saved = await PresetsEditorDialogHelper.show(
                      context: context,
                      appState: appState,
                      mainPage: mainPage,
                    );
                    if (saved && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Presets updated.')),
                      );
                    }
                  },
                ),
                _buildSettingTile(
                  context,
                  'Favorites',
                  'View and edit favorites',
                  Icons.favorite,
                  onTap: () async {
                    final appState =
                        Provider.of<AppState>(context, listen: false);
                    await FavoritesManagerDialogHelper.show(
                      context: context,
                      appState: appState,
                      deviceLayer: mainPage.deviceLayer,
                    );
                  },
                ),
                _buildSettingTile(
                  context,
                  'Favorites On Air',
                  'View and tune to on-air favorites',
                  Icons.play_circle_outline,
                  onTap: () async {
                    final appState =
                        Provider.of<AppState>(context, listen: false);
                    await FavoritesOnAirDialogHelper.show(
                      context: context,
                      appState: appState,
                      deviceLayer: mainPage.deviceLayer,
                    );
                  },
                ),
                _buildSwitchTile(
                  context,
                  'Show On-Air Favorites Button',
                  'Show quick access button when favorites go on-air',
                  Icons.favorite_outline,
                  value: appState.showOnAirFavoritesPrompt,
                  onChanged: (value) {
                    appState.updateShowOnAirFavoritesPrompt(value);
                  },
                ),
                _buildSwitchTile(
                  context,
                  'Restart Song on Tune',
                  'Start at the beginning of the song when tuning',
                  Icons.fast_rewind,
                  value: appState.tuneStart,
                  onChanged: (value) {
                    appState.updateTuneStart(value);
                    final cfgCmd = SXiConfigureChannelSelectionCommand(
                        value ? PlayPoint.auto : PlayPoint.live, 5, 3, 1);
                    mainPage.deviceLayer.sendControlCommand(cfgCmd);
                  },
                ),
                _buildSwitchTile(
                  context,
                  'Slider Track Snapping',
                  'Snap to track boundaries when dragging the slider',
                  Icons.lock_clock,
                  value: appState.sliderSnapping,
                  onChanged: (value) {
                    appState.updateSliderSnapping(value);
                  },
                ),
                _buildMediaKeyBehaviorSelector(context, appState),
              ],
            ),
            const SizedBox(height: sectionSpacing),
            _buildSection(
              context,
              'Appearance',
              Icons.palette,
              [
                _buildThemeSelector(context, appState),
                const SizedBox(height: 8),
                _buildScaleSelector(context, appState),
                const SizedBox(height: 8),
                _buildDesignHeightSelector(context, appState),
              ],
            ),
            const SizedBox(height: sectionSpacing),
            _buildSection(
              context,
              'Connection',
              Icons.cable,
              [
                _buildSettingTile(
                  context,
                  'Port Selection',
                  'Select communication port',
                  Icons.settings_input_svideo,
                  onTap: () async {
                    final SerialTransport? transport =
                        await ConnectionDialogs.showConnectionType(
                      context,
                      barrierDismissible: true,
                    );
                    if (!context.mounted) return;
                    if (transport == null) return;

                    String portString = '';
                    Object? portObject;

                    if (transport == SerialTransport.serial) {
                      var res = await ConnectionDialogs.selectSerialPort(
                        context,
                        serialHelper: mainPage.serialHelper,
                        storageData: mainPage.appState.storageData,
                        canDismiss: true,
                      );
                      if (!context.mounted) return;
                      portString = res.$1;
                      portObject = res.$2;
                      if (portString.isEmpty && portObject == null) return;
                    } else if (transport == SerialTransport.network &&
                        !kIsWeb &&
                        !kIsWasm) {
                      final String? spec =
                          await ConnectionDialogs.showNetworkConfig(
                        context,
                      );
                      if (!context.mounted) return;
                      if (spec == null || spec.isEmpty) return;
                      portString = spec;
                      portObject = null;

                      await mainPage.appState.storageData
                          .save(SaveDataType.lastPort, portString);
                      await mainPage.appState.storageData.save(
                        SaveDataType.lastPortTransport,
                        SerialTransport.network.name,
                      );
                    } else {
                      return;
                    }

                    // Close current connection if any
                    try {
                      await mainPage.deviceLayer.close();
                    } catch (_) {}
                    if (!context.mounted) return;

                    final bool startupGate = mainPage.isStartupGateVisible;
                    if (startupGate && context.mounted) {
                      Navigator.of(context).pop();
                    }

                    // Attempt to reconnect using the chosen port
                    final success = await mainPage.connectToPort(
                      portString,
                      portObject,
                      transport: transport,
                    );
                    if (!context.mounted) return;

                    if (!startupGate && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(success
                            ? 'Connected to device.'
                            : 'Failed to connect to device.'),
                      ));
                    }
                  },
                ),
                _buildSecondaryBaudSelector(context, appState),
                _buildSettingTile(
                  context,
                  'Close Port',
                  'Disconnect from current port',
                  Icons.close,
                  onTap: () => mainPage.deviceLayer.close(),
                  isDestructive: true,
                ),
              ],
            ),
            const SizedBox(height: sectionSpacing),
            _buildSection(
              context,
              'Audio',
              Icons.volume_up,
              [
                _CollapsibleSection(
                  title: 'Hardware Equalizer',
                  icon: Icons.tune,
                  initiallyExpanded: false,
                  isSubsection: true,
                  children: [
                    _buildEqualizerWidget(context, mainPage, appState),
                  ],
                ),
                _buildSwitchTile(
                  context,
                  'Use App for Audio Playback',
                  'Enable audio playback through the app',
                  Icons.play_circle_outline,
                  value: appState.enableAudio,
                  onChanged: (value) async {
                    appState.updateEnableAudio(value);

                    if (value) {
                      // If enabling audio, start immediately with default (helps on Web)
                      // Ensure microphone permission prior to device selection
                      final granted = await mainPage.audioController
                          .ensureMicrophonePermission();
                      if (!granted) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Microphone permission was denied by the system.')),
                          );
                        }
                        appState.updateEnableAudio(false);
                        return;
                      }
                      if (context.mounted) {
                        await _showSelectAudioInputDevice(context);
                      }
                    } else {
                      // If disabling audio, stop audio thread
                      mainPage.audioController.stopAudioThread();
                    }
                  },
                ),
                const SizedBox(height: 8),
                if (appState.enableAudio) ...[
                  _buildSampleRateSelector(context, appState),
                  _buildSettingTile(
                    context,
                    'Audio Input Device',
                    'Select audio input source',
                    Icons.mic,
                    onTap: () => _showSelectAudioInputDevice(context),
                  ),
                  if (!kIsWeb && !kIsWasm && Platform.isAndroid) ...[
                    _buildAudioOutputSection(context),
                    _buildAndroidAudioInterruptionToggle(context),
                  ],
                  _buildSettingTile(
                    context,
                    'Reset Audio Settings',
                    'Clear saved audio preferences',
                    Icons.refresh,
                    onTap: () => _resetAudioSettings(context),
                    isDestructive: true,
                  ),
                ],
              ],
            ),
            const SizedBox(height: sectionSpacing),
            _buildSection(
              context,
              'System Info',
              Icons.info_outline,
              [
                _buildSystemInfoWidget(context, appState),
              ],
            ),
            const SizedBox(height: sectionSpacing),
            _buildSection(
              context,
              'Data',
              Icons.storage,
              [
                _buildSwitchTile(
                  context,
                  'Disable Analytics',
                  'Stops sending anonymous usage events',
                  Icons.insights,
                  value: appState.analyticsDisabled,
                  onChanged: (value) {
                    appState.updateAnalyticsDisabled(value);
                  },
                ),
                _buildSettingTile(
                  context,
                  'Open Data Directory',
                  'Open the directory where application data is stored',
                  Icons.folder_open,
                  onTap: () => _openSupportDirectory(),
                ),
                _buildSettingTile(
                  context,
                  'Clear All Data',
                  'Delete all saved application data',
                  Icons.delete_forever,
                  onTap: () => _showClearDataDialog(context, appState),
                  isDestructive: true,
                ),
              ],
            ),
            const SizedBox(height: sectionSpacing),
            _buildSection(
              context,
              'Debug',
              Icons.developer_mode,
              [
                _CollapsibleSection(
                  title: 'Logging',
                  icon: Icons.list_alt_rounded,
                  initiallyExpanded: false,
                  isSubsection: true,
                  children: [
                    _buildSettingTile(
                      context,
                      'Log Level',
                      _logLevelLabel(appState.logLevel),
                      Icons.report,
                      onTap: () => _showLogLevelDialog(context),
                    ),
                    if (!kIsWeb) ...[
                      _buildSettingTile(
                        context,
                        'View Log',
                        'Open a scrollable log viewer',
                        Icons.article_outlined,
                        onTap: () => _showLogViewer(context),
                      ),
                      _buildSettingTile(
                        context,
                        'Open Log File',
                        'Open the log in the system viewer',
                        Icons.description_outlined,
                        onTap: () => _openLogFile(),
                      ),
                    ]
                  ],
                ),
                _buildSwitchTile(
                  context,
                  'Debug Mode',
                  'Enable debug features and tools',
                  Icons.bug_report,
                  value: appState.debugMode,
                  onChanged: (value) {
                    appState.updateDebugMode(value);
                  },
                ),
                if (appState.debugMode) ...[
                  _buildSettingTile(
                    context,
                    'Streaming (Beta)',
                    'Test internet streaming functionality',
                    Icons.wifi_tethering,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => StreamingBetaPage(
                            deviceLayer: mainPage.deviceLayer,
                            appState: appState,
                          ),
                        ),
                      );
                    },
                  ),
                  _buildSwitchTile(
                    context,
                    'Device-layer Frame Trace',
                    'Write RX/TX frames to logs/link_trace.log',
                    Icons.link,
                    value: appState.linkTraceEnabled,
                    onChanged: (value) {
                      if (value) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              backgroundColor: Colors.yellow,
                              duration: Duration(seconds: 10),
                              content: Text(
                                  'Link Trace could be huge! Please remember to disable it after use.')),
                        );
                      }
                      appState.updateLinkTraceEnabled(value);
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Monitor Data Services',
                    'Choose which data services to monitor',
                    Icons.tune,
                    onTap: () => _showDataServicesPicker(context, appState),
                  ),
                  _buildSettingTile(
                    context,
                    'Dump DMI to console',
                    'Log DMI-to-DSI mappings',
                    Icons.info_outline,
                    onTap: () {
                      for (var val in DataServiceIdentifier.values) {
                        if (DataServiceIdentifier.dmiToDsiMap
                            .containsValue(val)) {
                          logger.d(val.toString());
                        }
                      }
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Play Test Tone (software)',
                    'Software-generated 440 Hz for 3s',
                    Icons.volume_up,
                    onTap: () {
                      mainPage.audioController.playTestTone(440, 3);
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Play Test Tone (hardware)',
                    'Continuously hardware-generated 440 Hz',
                    Icons.volume_up,
                    onTap: () {
                      final cmd = SXiAudioToneGenerateCommand(
                        440,
                        AudioLeftRightType.both,
                        AudioAlertType.none,
                        -26,
                      );
                      mainPage.deviceLayer.sendControlCommand(cmd);
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Stop Test Tone (hardware)',
                    'Stop hardware-generated tone',
                    Icons.volume_up,
                    onTap: () {
                      final cmd = SXiAudioToneGenerateCommand(
                        440,
                        AudioLeftRightType.none,
                        AudioAlertType.none,
                        0,
                      );
                      mainPage.deviceLayer.sendControlCommand(cmd);
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Play Test Alert 1 (hardware)',
                    'Hardware-generated alert tone',
                    Icons.volume_up,
                    onTap: () {
                      final cmd = SXiAudioToneGenerateCommand(
                        0,
                        AudioLeftRightType.none,
                        AudioAlertType.alert1,
                        0,
                      );
                      mainPage.deviceLayer.sendControlCommand(cmd);
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Play Test Alert 2 (hardware)',
                    'Hardware-generated alert tone',
                    Icons.volume_up,
                    onTap: () {
                      final cmd = SXiAudioToneGenerateCommand(
                        0,
                        AudioLeftRightType.none,
                        AudioAlertType.alert2,
                        0,
                      );
                      mainPage.deviceLayer.sendControlCommand(cmd);
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Show SID to Channel ID mapping',
                    'Display SID to Channel ID mapping',
                    Icons.radio,
                    onTap: () => _showSidChannelIdMapping(context),
                  ),
                  _buildSettingTile(
                    context,
                    'Show Images with Unassigned Channels',
                    'Display channel logos with unassigned channels',
                    Icons.bug_report_outlined,
                    onTap: () => _showMissingSIDs(context),
                  ),
                  _buildSettingTile(
                    context,
                    'Stop All Audio',
                    'Stop audio capture/playback threads',
                    Icons.volume_off,
                    onTap: () {
                      mainPage.audioController.stopAudioThread();
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Ping Device',
                    'Send a ping command to the device',
                    Icons.wifi,
                    onTap: () {
                      mainPage.deviceLayer.sendControlCommand(SXiPingCommand());
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Power Off Device',
                    'Requires unplugging the device to turn back on',
                    Icons.power_settings_new,
                    onTap: () {
                      mainPage.deviceLayer
                          .sendControlCommand(SXiPowerModeCommand(false));
                    },
                  ),
                  _buildSettingTile(
                      context,
                      'Monitor All Data Services',
                      'Monitor all data services (this will take a few seconds)',
                      Icons.monitor, onTap: () async {
                    for (var val in DataServiceIdentifier.values) {
                      if (val != DataServiceIdentifier.none) {
                        mainPage.deviceLayer.sendControlCommand(
                            SXiMonitorDataServiceCommand(
                                DataServiceMonitorUpdateType
                                    .startMonitorForService,
                                val));
                        await Future.delayed(const Duration(milliseconds: 500));
                      }
                    }
                  }),
                  _buildSettingTile(
                    context,
                    'Clear Radar Data',
                    'Delete saved radar tiles and raw dumps',
                    Icons.delete_sweep,
                    onTap: () async {
                      final appState =
                          Provider.of<AppState>(context, listen: false);
                      appState.clearRadarOverlays();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Cleared radar data.'),
                          duration: const Duration(seconds: 2),
                        ));
                      }
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'Stop Monitoring Data Services',
                    'Stop monitoring data services',
                    Icons.stop,
                    onTap: () {
                      mainPage.deviceLayer.sendControlCommand(
                          SXiMonitorDataServiceCommand(
                              DataServiceMonitorUpdateType
                                  .stopMonitorForAllServices,
                              DataServiceIdentifier.none));
                    },
                  ),
                  _buildSettingTile(
                    context,
                    'EPG Schedule',
                    'Show the EPG schedule',
                    Icons.schedule,
                    onTap: () =>
                        EpgScheduleDialog.show(context, mainPage.sxiLayer),
                  ),
                  _buildSettingTile(context, 'Auth State',
                      'Log the auth status', Icons.security,
                      onTap: () => {
                            mainPage.deviceLayer.sendControlCommand(
                                SXiDeviceAuthenticationCommand())
                          }),
                  _buildSettingTile(context, 'Package Report',
                      'Log the active package report', Icons.report,
                      onTap: () => {
                            mainPage.deviceLayer.sendControlCommand(
                                SXiPackageCommand(PackageOptionType.report, 1))
                          }),
                  _buildSettingTile(context, 'Package Query',
                      'Log the active package query', Icons.query_stats,
                      onTap: () => {
                            mainPage.deviceLayer.sendControlCommand(
                                SXiPackageCommand(PackageOptionType.query, 1))
                          }),
                  _buildSettingTile(context, 'Package Validate',
                      'Log the active package validation', Icons.check,
                      onTap: () => {
                            mainPage.deviceLayer.sendControlCommand(
                                SXiPackageCommand(
                                    PackageOptionType.validate, 1))
                          }),
                ],
              ],
            ),
            const SizedBox(height: sectionSpacing),
            _buildAboutHeader(context),
          ],
        ),
      ),
    );
  }

  void _showLogViewer(BuildContext context) async {
    String content = '';
    try {
      await AppLogger.instance.ensureFileOutputReady();
      final path = AppLogger.instance.logFilePath;
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          // Read the last ~64KB to keep it snappy
          final int length = await file.length();
          final int start = length > 64 * 1024 ? (length - 64 * 1024) : 0;
          content = await file.openRead(start).transform(utf8.decoder).join();
        }
      }
    } catch (_) {
      // Ignore
    }

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final scrollController = ScrollController();
        return AlertDialog(
          title: const Text('Application Log'),
          content: SizedBox(
            width: 600,
            height: 400,
            child: Scrollbar(
              controller: scrollController,
              child: SingleChildScrollView(
                controller: scrollController,
                child: SelectableText(
                  content.isEmpty ? 'No log content available.' : content,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _showDataServicesPicker(BuildContext context, AppState appState) {
    final Set<DataServiceIdentifier> working =
        Set<DataServiceIdentifier>.from(appState.monitoredDataServices);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setState) {
          return AlertDialog(
            title: const Text('Select Data Services'),
            content: SizedBox(
              width: 600,
              height: 420,
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final d in DataServiceIdentifier.values)
                      if (d != DataServiceIdentifier.none)
                        FilterChip(
                          label: Text(
                              '${d.name} (0x${d.value.toRadixString(16).toUpperCase()})'),
                          selected: working.contains(d),
                          onSelected: (sel) {
                            setState(() {
                              if (sel) {
                                working.add(d);
                              } else {
                                working.remove(d);
                              }
                            });
                          },
                        ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final previous = Set<DataServiceIdentifier>.from(
                      appState.monitoredDataServices);
                  appState.updateMonitoredDataServices(working);
                  // Send monitor commands for changes
                  _applyDataServiceMonitoring(previous, working);
                  Navigator.of(ctx).pop();
                },
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
  }

  void _applyDataServiceMonitoring(Set<DataServiceIdentifier> previous,
      Set<DataServiceIdentifier> selected) {
    final toStart = selected.difference(previous);
    final toStop = previous.difference(selected);
    for (final d in toStart) {
      final cfgCmd = SXiMonitorDataServiceCommand(
        DataServiceMonitorUpdateType.startMonitorForService,
        d,
      );
      mainPage.deviceLayer.sendControlCommand(cfgCmd);
    }
    for (final d in toStop) {
      final cfgCmd = SXiMonitorDataServiceCommand(
        DataServiceMonitorUpdateType.stopMonitorForService,
        d,
      );
      mainPage.deviceLayer.sendControlCommand(cfgCmd);
    }
  }

  String _logLevelLabel(Level level) {
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

  Future<void> _showLogLevelDialog(BuildContext context) async {
    final appState = Provider.of<AppState>(context, listen: false);
    final theme = Theme.of(context);
    final levels = <Level>[
      Level.trace,
      Level.debug,
      Level.info,
      Level.warning,
      Level.error,
      Level.fatal,
      Level.off,
    ];

    final selected = await showDialog<Level>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Select Log Level'),
          content: SizedBox(
            width: 360,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: levels.length,
              itemBuilder: (context, index) {
                final level = levels[index];
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
                  title: Text(_logLevelLabel(level)),
                  onTap: () => Navigator.pop(context, level),
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
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Log level set to ${_logLevelLabel(selected)}')),
        );
      }
    }
  }

  Widget _buildSection(
      BuildContext context, String title, IconData icon, List<Widget> children,
      {bool initiallyExpanded = false}) {
    return _CollapsibleSection(
      key: _sectionKeys[title] ?? ValueKey<String>(title),
      title: title,
      icon: icon,
      initiallyExpanded: initiallyExpanded,
      children: children,
    );
  }

  Widget _buildAboutHeader(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final String appName = 'Orbit';
        final String version = snapshot.data?.version ?? '—';
        final DateTime? installDate = snapshot.data?.installTime;
        final String installDateString = installDate != null
            ? 'Installed: ${installDate.toLocal().toString()}'
            : '';
        final String versionLabel = 'v$version';

        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$appName (${kIsWeb ? 'Web' : defaultTargetPlatform.name})',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        versionLabel,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      if (installDateString.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          installDateString,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingTile(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon, {
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ListTile(
          leading: Icon(
            icon,
            color: isDestructive
                ? theme.colorScheme.error
                : theme.colorScheme.primary,
          ),
          title: Text(
            title,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
              color: isDestructive
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchTile(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon, {
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: ListTile(
          leading: Icon(icon, color: theme.colorScheme.primary),
          title: Text(
            title,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
          trailing: Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildAudioOutputSection(BuildContext context) {
    final theme = Theme.of(context);
    final appState = Provider.of<AppState>(context);

    const routes = <String>['Speaker', 'Receiver', 'Headphones', 'Bluetooth'];

    String current = routes.contains(appState.androidAudioOutputRoute)
        ? appState.androidAudioOutputRoute
        : 'Speaker';

    void applyRoute(String route) {
      switch (route) {
        case 'Receiver':
          mainPage.audioController.switchToReceiver();
          break;
        case 'Headphones':
          mainPage.audioController.switchToHeadphones();
          break;
        case 'Bluetooth':
          mainPage.audioController.switchToBluetooth();
          break;
        case 'Speaker':
        default:
          mainPage.audioController.switchToSpeaker();
          break;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: ListTile(
        leading: Icon(Icons.volume_up, color: theme.colorScheme.primary),
        title: Text(
          'Audio Output Route',
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          'Android only',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
        trailing: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: current,
            onChanged: (value) {
              if (value == null) return;
              appState.updateAndroidAudioOutputRoute(value);
              applyRoute(value);
            },
            items: routes
                .map(
                  (r) => DropdownMenuItem<String>(
                    value: r,
                    child: Text(r),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildAndroidAudioInterruptionToggle(BuildContext context) {
    final appState = Provider.of<AppState>(context);
    return _buildSwitchTile(
      context,
      'Detect Audio Interruptions',
      'Android only. Pause input during Assistant/calls and resume after.',
      Icons.hearing,
      value: appState.detectAudioInterruptions,
      onChanged: (v) async {
        appState.updateDetectAudioInterruptions(v);
        // If audio is currently enabled, restart capture to apply behavior
        if (appState.enableAudio) {
          final main = mainPage;
          try {
            main.audioController.stopAudioThread();
          } catch (_) {}
          try {
            await main.audioController.startAudioThread(
              selectedDevice: null,
              androidAudioOutputRoute: appState.androidAudioOutputRoute,
              detectAudioInterruptions: v,
              preferredSampleRate: appState.audioSampleRate,
            );
          } catch (_) {}
        }
      },
    );
  }

  Widget _buildSecondaryBaudSelector(BuildContext context, AppState appState) {
    final theme = Theme.of(context);
    // Allowed baud rates matching device codes 0..4
    const List<int> baudRates = [57600, 115200, 230400, 460800, 921600];
    int current = baudRates.contains(appState.secondaryBaudRate)
        ? appState.secondaryBaudRate
        : 460800;

    return ListTile(
      leading: Icon(Icons.speed, color: theme.colorScheme.primary),
      title: Text(
        'Device Baud Rate',
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        'Speed of serial connection (default: 460800)',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: current,
          onChanged: (value) async {
            if (value == null) return;
            appState.updateSecondaryBaudRate(value);
            // If currently connected, offer to reconnect using new baud
            try {
              if (true) {
                // Show a brief snackbar hint
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                          'Baud changed. Reboot the device and reconnect.'),
                      duration: Duration(seconds: 5),
                    ),
                  );
                }
              }
            } catch (_) {}
          },
          items: baudRates
              .map(
                (r) => DropdownMenuItem<int>(
                  value: r,
                  child: Text('$r'),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildMediaKeyBehaviorSelector(
      BuildContext context, AppState appState) {
    final theme = Theme.of(context);

    const Map<MediaKeyBehavior, String> labels = {
      MediaKeyBehavior.channel: 'Channel Up/Down (default)',
      MediaKeyBehavior.presetCycle: 'Presets Left/Right',
      MediaKeyBehavior.track: 'Track Back/Forward',
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!isLandscape(context)) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.settings_remote,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Media Key Behavior',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Choose what the system rewind/forward keys control',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                            softWrap: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonHideUnderline(
                  child: SizedBox(
                    width: double.infinity,
                    child: DropdownButton<MediaKeyBehavior>(
                      isExpanded: true,
                      value: appState.mediaKeyBehavior,
                      onChanged: (value) {
                        if (value == null) return;
                        appState.updateMediaKeyBehavior(value);
                      },
                      items: MediaKeyBehavior.values
                          .map(
                            (v) => DropdownMenuItem<MediaKeyBehavior>(
                              value: v,
                              child: Text(labels[v] ?? v.name),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return ListTile(
          leading:
              Icon(Icons.settings_remote, color: theme.colorScheme.primary),
          title: Text(
            'Media Key Behavior',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          subtitle: Text(
            'Choose what the system rewind/forward keys control',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
          trailing: DropdownButtonHideUnderline(
            child: DropdownButton<MediaKeyBehavior>(
              value: appState.mediaKeyBehavior,
              onChanged: (value) {
                if (value == null) return;
                appState.updateMediaKeyBehavior(value);
              },
              items: MediaKeyBehavior.values
                  .map(
                    (v) => DropdownMenuItem<MediaKeyBehavior>(
                      value: v,
                      child: Text(labels[v] ?? v.name),
                    ),
                  )
                  .toList(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSampleRateSelector(BuildContext context, AppState appState) {
    final theme = Theme.of(context);
    const List<int> rates = [
      8000,
      16000,
      22050,
      24000,
      32000,
      44100,
      48000,
      96000
    ];
    int current = rates.contains(appState.audioSampleRate)
        ? appState.audioSampleRate
        : 48000;

    return ListTile(
      leading: Icon(Icons.settings_voice, color: theme.colorScheme.primary),
      title: Text(
        'Audio Sample Rate',
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        'Default: 48000 Hz',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
        ),
      ),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: current,
          onChanged: (value) async {
            if (value == null) return;
            final appState = Provider.of<AppState>(context, listen: false);
            final main = mainPage;
            // If sample rate changes, persist and restart audio if enabled
            appState.updateAudioSampleRate(value);
            if (appState.enableAudio) {
              try {
                main.audioController.stopAudioThread();
              } catch (_) {}
              try {
                await main.audioController.startAudioThread(
                  selectedDevice: null,
                  androidAudioOutputRoute: appState.androidAudioOutputRoute,
                  detectAudioInterruptions: appState.detectAudioInterruptions,
                  preferredSampleRate: value,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Audio restarted at $value Hz'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to restart audio: $e'),
                    ),
                  );
                }
              }
            }
          },
          items: rates
              .map(
                (r) => DropdownMenuItem<int>(
                  value: r,
                  child: Text('${r.toString()} Hz'),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildEqualizerWidget(
      BuildContext context, MainPageState mainPage, AppState appState) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(appState.eqSliderValues.length, (index) {
              String label;
              if (index == 0) {
                label = 'Vol';
              } else if (index == 11) {
                label = 'Gain';
              } else {
                var freq = 32 * pow(2, index - 1).toDouble();
                if (freq > 512) {
                  freq = freq / 1000;
                  label = '${freq.toStringAsFixed(0)}\nKHz';
                } else {
                  label = '${freq.toStringAsFixed(0)}\nHz';
                }
              }
              return Expanded(
                child: Column(
                  children: [
                    SizedBox(
                      height: 32,
                      child: Center(
                        child: Text(
                          label,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    RotatedBox(
                      quarterTurns: -1,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: theme.colorScheme.primary,
                          inactiveTrackColor:
                              theme.colorScheme.outline.withValues(alpha: 0.3),
                          thumbColor: theme.colorScheme.primary,
                          overlayColor:
                              theme.colorScheme.primary.withValues(alpha: 0.2),
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 8),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 16),
                        ),
                        child: Slider(
                          value: appState.eqSliderValues[index],
                          min: index == 0 ? -maxVol : -maxEq,
                          max: index == 0 ? maxVol : maxEq,
                          onChangeEnd: (value) {
                            if (index == 0) {
                              mainPage.sendVol();
                            } else {
                              mainPage.sendEq();
                            }
                          },
                          onChanged: (value) {
                            appState.updateEqValue(index, value);
                          },
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 24,
                      child: Center(
                        child: Text(
                          appState.eqSliderValues[index].round().toString(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 16),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                appState.resetEqValues();
                mainPage.sendEq();
                mainPage.sendVol();
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.refresh,
                      size: 16,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Reset Equalizer',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemInfoWidget(BuildContext context, AppState appState) {
    final theme = Theme.of(context);

    String getSubscriptionStatusText() {
      switch (appState.subscriptionStatus) {
        case 0:
          return 'None';
        case 1:
          return 'Partial';
        case 2:
          return 'Full';
        case 3:
        default:
          return 'Unknown';
      }
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Subscription Status
          _buildInfoRow(
            context,
            'Subscription Status',
            getSubscriptionStatusText(),
            Icons.subscriptions,
            theme.colorScheme.onSurface,
          ),
          const SizedBox(height: 12),

          // Signal Quality
          _buildInfoRowWithBar(
            context,
            'Signal Quality',
            getSignalIcon(
              appState.signalQuality,
              isAntennaConnected: appState.isAntennaConnected,
            ),
            SignalBar(
              level: appState.signalQuality,
              maxLevel: 4,
              isAntennaConnected: appState.isAntennaConnected,
            ),
          ),
          const SizedBox(height: 12),

          // Antenna Status
          _buildInfoRow(
            context,
            'Antenna Status',
            appState.isAntennaConnected ? 'Connected' : 'Disconnected',
            appState.isAntennaConnected
                ? Icons.satellite_alt
                : Icons.signal_cellular_connected_no_internet_0_bar,
            appState.isAntennaConnected
                ? theme.colorScheme.onSurface
                : theme.colorScheme.error,
          ),
          const SizedBox(height: 12),

          // Audio Presence
          _buildInfoRow(
            context,
            'Audio Presence',
            appState.audioPresence ? 'Playing' : 'No Audio',
            appState.audioPresence ? Icons.volume_up : Icons.volume_off,
            appState.audioPresence
                ? theme.colorScheme.onSurface
                : theme.colorScheme.error,
          ),
          const SizedBox(height: 12),

          // Audio Decoder Bitrate
          _buildInfoRow(
            context,
            'Audio Bitrate',
            appState.audioDecoderBitrate > 0
                ? '${appState.audioDecoderBitrate} kbps'
                : 'N/A',
            Icons.graphic_eq,
            appState.audioDecoderBitrate > 0
                ? theme.colorScheme.onSurface
                : theme.colorScheme.error,
          ),

          // Device Time
          if (appState.deviceTime != null) ...[
            const SizedBox(height: 12),
            _buildInfoRow(
              context,
              'Satellite Time',
              '${appState.deviceTime!.hour.toString().padLeft(2, '0')}:${appState.deviceTime!.minute.toString().padLeft(2, '0')} ${appState.deviceTime!.day}/${appState.deviceTime!.month}/${appState.deviceTime!.year}',
              Icons.access_time,
              theme.colorScheme.onSurface,
            ),
          ],

          // Hardware/Software Versions
          if (appState.moduleType.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildInfoRow(
              context,
              'Module Type',
              appState.moduleType,
              Icons.hardware,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Module HW Rev',
              appState.moduleHWRev,
              Icons.build,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Module SW Rev',
              appState.moduleSWRev,
              Icons.system_update,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'SXi Protocol Rev',
              appState.sxiRev,
              Icons.api,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Baseband Rev',
              appState.basebandRev,
              Icons.tune,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Hardware Decoder Rev',
              appState.hardwareDecoderRev,
              Icons.memory,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'RF Rev',
              appState.rfRev,
              Icons.radio,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'SPL Rev',
              appState.splRev,
              Icons.code,
              theme.colorScheme.onSurface,
            ),
          ],

          // Device Capabilities
          if (appState.bufferDuration > 0) ...[
            const SizedBox(height: 12),
            _buildInfoRow(
              context,
              'Buffer Duration',
              '${(appState.bufferDuration / 60).toStringAsFixed(0)} minutes',
              Icons.timer,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Max Smart Favorites',
              appState.maxSmartFavorites.toString(),
              Icons.favorite,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Max TuneMix',
              appState.maxTuneMix.toString(),
              Icons.shuffle,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Max Sports Flash',
              appState.maxSportsFlash.toString(),
              Icons.sports_soccer,
              theme.colorScheme.onSurface,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              context,
              'Max TrafficWatch',
              appState.maxTWNow.toString(),
              Icons.traffic,
              theme.colorScheme.onSurface,
            ),
          ],

          // Show subscription details
          // We only have these if it's the first load of the device
          if (appState.subscriptionReasonText.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildInfoRow(
              context,
              'Subscription Reason',
              appState.subscriptionReasonText,
              Icons.info_outline,
              theme.colorScheme.onSurface,
            ),
          ],

          if (appState.subscriptionPhoneNumber.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildInfoRow(
              context,
              'Contact Number',
              appState.subscriptionPhoneNumber,
              Icons.phone,
              theme.colorScheme.onSurface,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Text(
                value,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRowWithBar(
    BuildContext context,
    String label,
    IconData icon,
    Widget bar,
  ) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              FractionallySizedBox(
                widthFactor: 0.5,
                alignment: Alignment.centerLeft,
                child: bar,
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showClearDataDialog(BuildContext context, AppState appState) {
    showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete All Saved Data?'),
        content: const Text(
            'Are you sure you want to delete all saved data? This action cannot be undone.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, 'Cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.storageData.deleteAll();
              Navigator.pop(context, 'Ok');
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<bool> _openSupportDirectory() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final supportDir = Directory(appDir.path);
      if (!await supportDir.exists()) {
        await supportDir.create(recursive: true);
      }

      if (Platform.isWindows) {
        await Process.run('explorer', [supportDir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [supportDir.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [supportDir.path]);
      } else if (Platform.isAndroid) {
        bool success = false;

        // Try to open directory with intent approach
        try {
          logger.i('Trying to open directory with ACTION_OPEN_DOCUMENT_TREE');
          final intent = AndroidIntent(
            action: 'android.intent.action.OPEN_DOCUMENT_TREE',
            flags: <int>[0x10000000], // FLAG_ACTIVITY_NEW_TASK
          );

          await intent.launch();
          success = true;
          logger.i('Opened file picker using ACTION_OPEN_DOCUMENT_TREE');
        } catch (e) {
          logger.w('Failed to open directory with ACTION_OPEN_DOCUMENT_TREE',
              error: e);
        }

        return success;
      }
      return true;
    } catch (e) {
      logger.e('Error opening support directory', error: e);
      return false;
    }
  }

  Future<bool> _openLogFile() async {
    try {
      final logFilePath = AppLogger.instance.logFilePath;
      if (logFilePath == null) {
        return false;
      }

      final logFile = File(logFilePath);

      if (!await logFile.exists()) {
        await logFile.parent.create(recursive: true);
        await logFile.writeAsString('Log file created at ${DateTime.now()}\n');
      }

      logger.i('Opening log file at: ${logFile.path}');

      if (Platform.isAndroid) {
        if (await logFile.exists()) {
          try {
            final result = await OpenFile.open(logFile.path);
            if (result.type == ResultType.done) {
              return true;
            } else {
              logger.w('OpenFile result: ${result.message}');
            }
          } catch (e) {
            logger.w('Failed to open with OpenFile, trying intent approaches',
                error: e);
          }

          return false;
        } else {
          logger.w('Log file does not exist at: ${logFile.path}');
          return false;
        }
      } else {
        final uri = Uri.file(logFile.path);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
          return true;
        } else {
          logger.e('Could not launch $uri');
          return false;
        }
      }
    } catch (e) {
      logger.e('Error opening log file', error: e);
      return false;
    }
  }

  Future<void> _showSelectAudioInputDevice(BuildContext context) async {
    final appState = Provider.of<AppState>(context, listen: false);
    List<dynamic> availableDevices = [];
    List<String> deviceNames = [];

    Future<List<String>> loadDevices() async {
      try {
        // Clear and reload to avoid duplicates and flicker
        deviceNames.clear();
        availableDevices =
            await mainPage.audioController.getAvailableInputDevices();

        for (var device in availableDevices) {
          var deviceName = mainPage.audioController.getDeviceName(device);
          deviceNames.add(deviceName);
        }

        return deviceNames;
      } catch (e) {
        logger.w('Error loading audio devices: $e');
        return ['Error loading devices'];
      }
    }

    Future<List<String>> devicesFuture = loadDevices();

    dynamic selectedDevice = await showDialog<dynamic>(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateDialog) {
            return AlertDialog(
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Select Audio Input Device',
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh Devices',
                    onPressed: () {
                      setStateDialog(() {
                        devicesFuture = loadDevices();
                      });
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Cancel',
                    onPressed: () {
                      Navigator.pop(context, null);
                    },
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: FutureBuilder<List<String>>(
                  future: devicesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Text('Error: ${snapshot.error}'));
                    }
                    final items = snapshot.data ?? [];
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          title: Text(items[index]),
                          onTap: () {
                            if (index < availableDevices.length) {
                              Navigator.pop(context, availableDevices[index]);
                            } else {
                              Navigator.pop(context, null);
                            }
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );

    if (selectedDevice != null) {
      // Save the selected device
      var deviceName = mainPage.audioController.getDeviceName(selectedDevice);
      appState.storageData.save(SaveDataType.lastAudioDevice, deviceName);

      // Stop current audio and restart with new device
      mainPage.audioController.stopAudioThread();
      try {
        await mainPage.audioController.startAudioThread(
            selectedDevice: selectedDevice,
            androidAudioOutputRoute: appState.androidAudioOutputRoute,
            detectAudioInterruptions: appState.detectAudioInterruptions,
            preferredSampleRate: appState.audioSampleRate);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Audio device changed to: $deviceName')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to start audio: $e')),
          );
        }
      }
    }
  }

  Future<void> _resetAudioSettings(BuildContext context) async {
    final appState = Provider.of<AppState>(context, listen: false);

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Reset Audio Settings'),
          content: const Text(
              'This will clear your saved audio preferences and you will be prompted to configure audio again on next startup. Continue?'),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.pop(context, false),
            ),
            TextButton(
              child: const Text('Reset'),
              onPressed: () => Navigator.pop(context, true),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      // Clear saved audio settings
      await appState.storageData.delete(SaveDataType.enableAudio);
      await appState.storageData.delete(SaveDataType.lastAudioDevice);
      await appState.storageData.delete(SaveDataType.audioSampleRate);
      appState.updateAudioSampleRate(48000);

      // Stop current audio
      mainPage.audioController.stopAudioThread();
      appState.updateEnableAudio(false);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio settings reset successfully')),
        );
      }
    }
  }

  Widget _buildThemeSelector(BuildContext context, AppState appState) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Theme',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildThemeButton(
                context,
                'Light',
                Icons.light_mode,
                ThemeMode.light,
                appState.themeMode == ThemeMode.light,
                () => appState.updateThemeMode(ThemeMode.light),
              ),
              _buildThemeButton(
                context,
                'Dark',
                Icons.dark_mode,
                ThemeMode.dark,
                appState.themeMode == ThemeMode.dark,
                () => appState.updateThemeMode(ThemeMode.dark),
              ),
              _buildThemeButton(
                context,
                'System',
                Icons.settings_brightness,
                ThemeMode.system,
                appState.themeMode == ThemeMode.system,
                () => appState.updateThemeMode(ThemeMode.system),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScaleSelector(BuildContext context, AppState appState) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Text Scale',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: appState.textScale,
                  min: 0.7,
                  max: 1.8,
                  divisions: 11,
                  label: '${(appState.textScale * 100).round()}%',
                  onChanged: (value) => appState.updateUiScale(value),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  '${(appState.textScale * 100).round()}%',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildScalePresetButton(context, 'Smaller', 0.85, appState),
                _buildScalePresetButton(context, 'Default', 1.0, appState),
                _buildScalePresetButton(context, 'Large', 1.25, appState),
                _buildScalePresetButton(context, 'XL', 1.5, appState),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesignHeightSelector(BuildContext context, AppState appState) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'UI Scale',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: appState.uiScale,
                  min: 360,
                  max: 1440,
                  divisions: 27,
                  label: appState.uiScale.round().toString(),
                  onChanged: (value) => appState.updateDesignHeight(value),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  appState.uiScale.round().toString(),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildDesignHeightPresetButton(context, 'Phone', 640, appState),
                _buildDesignHeightPresetButton(
                    context, 'Default', 720, appState),
                _buildDesignHeightPresetButton(
                    context, 'Tablet', 900, appState),
                _buildDesignHeightPresetButton(
                    context, 'Large', 1080, appState),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesignHeightPresetButton(
      BuildContext context, String label, double value, AppState appState) {
    final theme = Theme.of(context);
    final bool selected = (appState.uiScale - value).abs() < 1.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => appState.updateDesignHeight(value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: selected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScalePresetButton(
      BuildContext context, String label, double value, AppState appState) {
    final theme = Theme.of(context);
    final bool selected = (appState.textScale - value).abs() < 0.01;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => appState.updateUiScale(value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: selected
                  ? theme.colorScheme.onPrimaryContainer
                  : theme.colorScheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThemeButton(
    BuildContext context,
    String label,
    IconData icon,
    ThemeMode themeMode,
    bool isSelected,
    VoidCallback onPressed,
  ) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSelected
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurface,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showMissingSIDs(BuildContext context) async {
    final appState = Provider.of<AppState>(context, listen: false);
    var stg = appState.storageData;
    Map<int, ChannelLogoInfo> missingSidLogos = {};

    for (var img in stg.imageMap.values) {
      for (var svc in stg.serviceGraphicsReferenceMap.values) {
        if (img.chanLogoId == svc.referenceId && img.seqNum == svc.sequence) {
          var channel = appState.sidMap[svc.sid];
          if (channel == null) {
            missingSidLogos[svc.sid] = img;
          }
        }
      }
    }

    if (missingSidLogos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No unassigned images are loaded.')),
      );
      return;
    }

    await showDialog<int>(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        var list = missingSidLogos.entries.toList();
        return AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Images with Unassigned Channels'),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          content: SizedBox(
            width: 400,
            height: 600,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (context, index) {
                return ListTile(
                  leading: SizedBox(
                    width: 80,
                    child: Text(
                      'SID: ${list[index].key}\nChannel: ${appState.getChannelIdFromSid(list[index].key)}',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  title: Container(
                    height: 80,
                    width: 80,
                    decoration: BoxDecoration(
                      border: Border.all(width: 1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.memory(
                        Uint8List.fromList(list[index].value.imageData),
                        cacheHeight: 160,
                        cacheWidth: 160,
                        fit: BoxFit.scaleDown,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Icon(
                              Icons.broken_image,
                              color: Colors.grey,
                              size: 32,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _showSidChannelIdMapping(BuildContext context) {
    final appState = Provider.of<AppState>(context, listen: false);
    if (appState.sidMap.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No channel data available')),
      );
      return;
    }

    final entries = appState.sidMap.entries.toList();
    String sortBy = 'channel';
    bool ascending = true;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            final sorted = List.of(entries)
              ..sort((a, b) {
                int cmp;
                if (sortBy == 'sid') {
                  cmp = a.key.compareTo(b.key);
                } else {
                  cmp = a.value.channelNumber.compareTo(b.value.channelNumber);
                }
                return ascending ? cmp : -cmp;
              });

            return AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('SID to Channel ID Mapping'),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              content: SizedBox(
                width: 520,
                height: 600,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('Sort by:'),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: sortBy,
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              sortBy = value;
                            });
                          },
                          items: const [
                            DropdownMenuItem(
                              value: 'sid',
                              child: Text('SID'),
                            ),
                            DropdownMenuItem(
                              value: 'channel',
                              child: Text('Channel ID'),
                            ),
                          ],
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: ascending ? 'Ascending' : 'Descending',
                          icon: Icon(ascending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward),
                          onPressed: () {
                            setState(() {
                              ascending = !ascending;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: sorted.length,
                        itemBuilder: (context, index) {
                          final sid = sorted[index].key;
                          final data = sorted[index].value;
                          return ListTile(
                            leading: SizedBox(
                              width: 140,
                              child: Text(
                                'SID: $sid',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w500),
                              ),
                            ),
                            title: Text(
                                'Channel ${data.channelNumber} — ${data.channelName}'),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _CollapsibleSection extends StatefulWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool initiallyExpanded;
  final bool isSubsection;

  const _CollapsibleSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.initiallyExpanded = false,
    this.isSubsection = false,
  });

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  late bool _isExpanded;
  bool get isExpanded => _isExpanded;

  void setExpanded(bool expanded) {
    if (_isExpanded == expanded) return;
    setState(() {
      _isExpanded = expanded;
    });
  }

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.isSubsection) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              hoverColor: theme.colorScheme.primary.withValues(alpha: 0.05),
              onTap: () {
                setState(() {
                  _isExpanded = !_isExpanded;
                });
              },
              child: ListTile(
                leading: Icon(widget.icon, color: theme.colorScheme.primary),
                title: Text(
                  widget.title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                trailing: AnimatedRotation(
                  turns: _isExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.expand_more,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            crossFadeState: _isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding:
                  const EdgeInsets.only(left: 16.0, right: 8.0, bottom: 8.0),
              child: Column(children: widget.children),
            ),
          ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(widget.isSubsection ? 8 : 12),
        border: Border.all(
          color: widget.isSubsection
              ? theme.colorScheme.outline.withValues(alpha: 0.15)
              : theme.colorScheme.outline.withValues(alpha: 0.2),
          width: widget.isSubsection ? 1 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
              onTap: () {
                setState(() {
                  _isExpanded = !_isExpanded;
                });
              },
              child: Padding(
                padding: EdgeInsets.all(widget.isSubsection ? 12.0 : 16.0),
                child: Row(
                  children: [
                    Icon(
                      widget.icon,
                      color: widget.isSubsection
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.primary,
                      size: widget.isSubsection ? 18 : 20,
                    ),
                    SizedBox(width: widget.isSubsection ? 6 : 8),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: widget.isSubsection
                              ? FontWeight.w500
                              : FontWeight.w600,
                          color: widget.isSubsection
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _isExpanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more,
                        color: widget.isSubsection
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            crossFadeState: _isExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: EdgeInsets.only(
                  left: widget.isSubsection ? 8.0 : 0.0,
                  right: widget.isSubsection ? 8.0 : 0.0,
                  bottom: widget.isSubsection ? 8.0 : 0.0),
              child: Column(children: widget.children),
            ),
          ),
        ],
      ),
    );
  }
}
