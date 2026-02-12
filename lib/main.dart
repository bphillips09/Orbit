// Main app class
import 'dart:async';
import 'dart:ui';
import 'dart:typed_data';
import 'package:orbit/telemetry/telemetry.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orbit/data/favorite.dart';
import 'package:provider/provider.dart';
import 'package:scaled_app/scaled_app.dart';
import 'package:orbit/logging.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/audio/audio_controller.dart';
import 'package:orbit/audio/background_audio_task.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:orbit/storage/storage_data.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/ui/channel_info_dialog.dart';
import 'package:orbit/ui/preset.dart';
import 'package:orbit/ui/settings.dart';
import 'package:orbit/ui/slider_track.dart';
import 'package:orbit/ui/epg_dialog.dart';
import 'package:orbit/ui/signal_quality_dialog.dart';
import 'package:orbit/ui/album_art.dart';
import 'package:orbit/ui/presets_editor.dart';
import 'package:orbit/helpers.dart';
import 'package:window_manager/window_manager.dart';
import 'package:orbit/update_checker.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:orbit/ui/unsupported_browser_app.dart';
import 'package:orbit/ui/favorite_dialog.dart';
import 'package:orbit/ui/favorites_on_air_dialog.dart';
import 'package:orbit/ui/welcome_dialog.dart';
import 'package:orbit/ui/connection_dialogs.dart';
import 'package:orbit/platform/head_unit_aux.dart';

// Audio service handler
AudioServiceHandler? audioServiceHandler;
const double maxEq = 12;
const double maxVol = 30;
const int initialBaudRate = 57600;
const String appID = "A-US-7679911409";

// This is where the magic happens
void main() async {
  await AppLogger.instance.runWithLogging(() async {
    logger.i('Orbit Boot...');

    // Initialize the scaled widgets binding
    ScaledWidgetsFlutterBinding.ensureInitialized(
      scaleFactor: (deviceSize) {
        const double heightOfDesign = 720;
        return deviceSize.height / heightOfDesign;
      },
    );

    // Never block startup on telemetry
    unawaited(Telemetry.initialize(appID, debug: kDebugMode));

    if (kIsWeb || kIsWasm) {
      try {
        final deviceInfo = DeviceInfoPlugin();
        final webInfo = await deviceInfo.webBrowserInfo;
        final BrowserName name = webInfo.browserName;
        final bool isChromium = name == BrowserName.chrome ||
            name == BrowserName.edge ||
            name == BrowserName.opera;

        if (defaultTargetPlatform == TargetPlatform.android || !isChromium) {
          logger.w('Unsupported browser detected: ${webInfo.userAgent}');
          Telemetry.event(
              "unsupported_browser", {"browser": webInfo.browserName.name});
          runApp(const UnsupportedBrowserApp());
          return;
        }
      } catch (e) {
        logger.w('Failed to detect browser info: $e');
        // If detection fails, show message instead of proceeding
        Telemetry.event("unsupported_browser", {"browser": "Unknown"});
        runApp(const UnsupportedBrowserApp());
        return;
      }
    }

    // Ensure the file output is initialized
    await AppLogger.instance.ensureFileOutputReady();

    // If not Web/WASM and on a desktop platform, initialize the window manager
    if (!kIsWeb &&
        !kIsWasm &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      await windowManager.ensureInitialized();

      WindowOptions windowOptions = WindowOptions(
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        title: 'Orbit',
        titleBarStyle: TitleBarStyle.normal,
      );

      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }

    runApp(const OrbitApp());
  });
}

class OrbitApp extends StatelessWidget {
  const OrbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: Consumer<AppState>(
        builder: (context, appState, child) {
          return MaterialApp(
            // Allow drag scrolling on desktop/web
            scrollBehavior: const MaterialScrollBehavior().copyWith(
              dragDevices: {PointerDeviceKind.mouse, PointerDeviceKind.touch},
            ),
            title: 'Orbit',
            themeMode: appState.themeMode,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            builder: (context, child) {
              // Apply UI scaling when the scale setting is changed
              final mq = MediaQuery.of(context);
              final double effectiveScale =
                  (appState.textScale <= 0 ? 1.0 : appState.textScale)
                      .clamp(0.6, 2.0)
                      .toDouble();
              return MediaQuery(
                data: mq.copyWith(
                  textScaler: TextScaler.linear(effectiveScale),
                  // Apply additional scaling to overall pixel ratio
                  devicePixelRatio: mq.devicePixelRatio * effectiveScale,
                ),
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: const MainPage(),
          );
        },
      ),
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  MainPageState createState() => MainPageState();
}

class MainPageState extends State<MainPage>
    with WindowListener, WidgetsBindingObserver {
  static const String _setupDialogRouteUseNativeAux = 'setup.use_native_aux';
  static const String _setupDialogRouteUseAudio = 'setup.use_audio';
  static const String _setupDialogRouteSelectAudioDevice =
      'setup.select_audio_device';

  late SXiLayer sxiLayer;
  late DeviceLayer deviceLayer;
  late SystemConfiguration _loadedConfig;
  late AppState appState;
  final audioController = AudioController();
  bool _windowCloseInProgress = false;
  var availablePorts = [];
  double transportValue = 0;
  bool transportDragging = false;
  TrackSnapInfo? currentSnapInfo;
  GlobalKey sliderKey = GlobalKey();
  bool _isLoading = true;
  bool _startupInProgress = false;
  bool _suppressFatalConnectionDialogs = false;
  String? _lastStartupConnectionError;
  bool _deviceConnected = false;
  bool _startupGateVisible = false;
  String _startupGateMessage = '';
  bool _startupCompleted = false;
  bool _startupCompletionInProgress = false;
  bool initiatedPlayback = false;
  bool _audioServiceInitialized = false;
  String _connectionDetails = '';
  Image? currentChannelImage;
  final serialHelper = SerialHelper();
  final channelTextController = TextEditingController();
  final FocusNode channelTextFocusNode = FocusNode();
  final mainScrollController = ScrollController();
  final mainListController = ListController();
  final categoryScrollController = ScrollController();
  final categoryListController = ListController();
  final GlobalKey<PresetCarouselState> presetCarouselKey =
      GlobalKey<PresetCarouselState>();
  static const double sliderDragCancelMarginPx = 28.0;
  double? _transportValueBeforeDrag;
  bool _sliderDragCanceled = false;
  // Track the displayed warning types to prevent duplicates
  final Set<String> _currentlyDisplayedWarnings = <String>{};
  DateTime? _lastOnAirPromptAt;
  Timer? _onAirShowTimer;
  String? _pendingOnAirKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    logger.d('Initializing...');

    if (!kIsWeb &&
        !kIsWasm &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        checkForAppUpdates(context);
      }
    });

    // Get the app state
    appState = Provider.of<AppState>(context, listen: false);

    // Create a disconnected layer for the UI
    sxiLayer = SXiLayer(appState);
    deviceLayer = DeviceLayer(
      sxiLayer,
      '',
      initialBaudRate,
      transport: SerialTransport.serial,
      onConnectionDetailChanged: onConnectionDetailsUpdated,
      onMessage: onMessage,
      onError: onDeviceConnectionError,
      onClearMessages: () {
        clearAllMessages();
      },
    );
    sxiLayer.deviceLayer = deviceLayer;

    // Initialize the app state
    appState.initialize().then((_) async {
      Telemetry.event("app_started", {"first_run": !appState.welcomeSeen});

      var session = await AudioSession.instance;
      await session.configure(
        // Configure the AudioSession
        const AudioSessionConfiguration(
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            //flags: AndroidAudioFlags.audibilityEnforced,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          // Treat ducking as pause so we fully yield during Assistant, calls, etc.
          androidWillPauseWhenDucked: true,
        ),
      );

      logger.i('AudioSession configured success');

      // Show first-time welcome
      if (!appState.welcomeSeen) {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (mounted) {
            await WelcomeDialog.show(context, () {
              appState.updateWelcomeSeen(true);
            });
          }
        } catch (_) {}
      }

      // Listen for playback changes
      appState.playbackInfoNotifier.addListener(onPlaybackInfoChanged);
      appState.playbackStateNotifier.addListener(onPlaybackStateChanged);
      appState.favoriteOnAirNotifier.addListener(onFavoriteOnAir);

      try {
        await startupSequence();
      } catch (e) {
        logger.e('Startup sequence failed: $e');
        showStartupLoadError(e.toString());
      }
    });
  }

  void _showStartupGate(String message) {
    if (!mounted) return;
    setState(() {
      _startupGateVisible = true;
      _startupGateMessage = message;
      _isLoading = false;
      _connectionDetails = '';
    });
  }

  void _hideStartupGate() {
    if (!mounted) return;
    setState(() {
      _startupGateVisible = false;
      _startupGateMessage = '';
    });
  }

  bool get isStartupGateVisible => _startupGateVisible;

  Future<bool> connectToPort(
    String portString,
    Object? portObject, {
    SerialTransport transport = SerialTransport.serial,
    bool persistPort = true,
  }) async {
    // Ensure any selection dialogs are gone so the main progress overlay is visible
    try {
      await clearAllMessages();
    } catch (_) {}

    _hideStartupGate();
    try {
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {}

    if (persistPort && !kIsWeb && !kIsWasm && portString.isNotEmpty) {
      try {
        await appState.storageData.save(SaveDataType.lastPort, portString);
        await appState.storageData
            .save(SaveDataType.lastPortTransport, transport.name);
      } catch (_) {}
    }

    final bool prevSuppress = _suppressFatalConnectionDialogs;
    _suppressFatalConnectionDialogs = true;
    _lastStartupConnectionError = null;

    // Make sure we have a fresh protocol layer bound to the new device layer
    sxiLayer = SXiLayer(appState);

    final bool ok =
        await tryStartup(portString, portObject, transport: transport);
    _suppressFatalConnectionDialogs = prevSuppress;

    if (!ok) {
      final err = (_lastStartupConnectionError ?? '').trim();
      _showStartupGate(err.isEmpty
          ? 'Couldn\'t connect. Check the port/device and try again.'
          : 'Couldn\'t connect.\n$err');
      return false;
    }

    await onConnected();
    return true;
  }

  Future<void> _openSettings() async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsPage(mainPage: this),
      ),
    );
  }

  Future<void> onConnected() async {
    if (_startupCompleted || _startupCompletionInProgress) {
      _hideStartupGate();
      return;
    }

    _startupCompletionInProgress = true;
    try {
      await clearAllMessages();
      await setupAudio();
      onPlaybackStateChanged();
      _startupCompleted = true;
    } finally {
      _startupCompletionInProgress = false;
      _hideStartupGate();
    }
  }

  Future<void> _connectFromStartupGate() async {
    final (SerialTransport, String, Object?) selection =
        await _promptForConnection(
      previousNetworkSpec: null,
      canDismissSerial: true,
      barrierDismissible: true,
      message: null,
    );

    final SerialTransport transport = selection.$1;
    final String portString = selection.$2;
    final Object? portObject = selection.$3;
    if (portString.isEmpty && portObject == null) {
      _showStartupGate(
          _startupGateMessage.isEmpty ? 'Not connected.' : _startupGateMessage);
      return;
    }
    await connectToPort(portString, portObject, transport: transport);
  }

  // Show a dialog if the startup sequence fails
  void showStartupLoadError(String error) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Error Loading Data'),
          content: Text('An error occurred:\n$error'),
          actions: <Widget>[
            TextButton(
              child: const Text('Clear Data and Retry'),
              onPressed: () async {
                Navigator.of(context).pop();
                await appState.storageData.deleteAll();
                await clearAllMessages();
                startupSequence();
              },
            ),
            TextButton(
              onPressed: _attemptCloseApp,
              child: const Text('Close App'),
            ),
            TextButton(
              child: const Text('Ignore'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // The device startup sequence
  Future<void> startupSequence() async {
    if (_startupInProgress) {
      logger.w('Startup sequence already in progress');
      return;
    }
    _startupInProgress = true;
    _suppressFatalConnectionDialogs = true;
    _lastStartupConnectionError = null;

    try {
      // Load system configuration
      logger.d('Loading system configuration...');
      _loadedConfig = SystemConfiguration(
        volume: appState.eqSliderValues[0].round(),
        defaultSid: appState.lastSid,
        eq: calcEq(),
        presets: appState.presets.map((preset) => preset.sid).toList(),
        favoriteSongIDs: appState.favorites
            .where((f) => f.type == FavoriteType.song)
            .map((f) => f.id)
            .toList(),
        favoriteArtistIDs: appState.favorites
            .where((f) => f.type == FavoriteType.artist)
            .map((f) => f.id)
            .toList(),
        tuneStart: appState.tuneStart,
      );

      String lastPortString = await appState.storageData.load(
            SaveDataType.lastPort,
          ) ??
          "";
      final String? lastPortTransportString =
          await appState.storageData.load(SaveDataType.lastPortTransport);
      Object? lastPortObject;

      if (lastPortString.isEmpty) {
        _showStartupGate(
          'No connection configured yet. Please select a connection.',
        );
        return;
      }

      // Initialize the SXi layer
      sxiLayer = SXiLayer(appState);

      SerialTransport? transport;
      if (lastPortTransportString == SerialTransport.network.name) {
        transport = SerialTransport.network;
      } else if (lastPortTransportString == SerialTransport.serial.name) {
        transport = SerialTransport.serial;
      }

      if (transport == null) {
        _showStartupGate(
          'Your saved connection needs to be reconfigured. Please select a new connection.',
        );
        return;
      }

      final bool startupSuccess = await tryStartup(
          lastPortString, lastPortObject,
          transport: transport);
      if (!startupSuccess) {
        final err = (_lastStartupConnectionError ?? '').trim();
        _showStartupGate(err.isEmpty
            ? 'Couldn\'t connect to the saved port.\n\nPlease select a new connection.'
            : 'Couldn\'t connect to the saved port.\n$err\n\nPlease select a new connection.');
        return;
      }

      await onConnected();
    } finally {
      _suppressFatalConnectionDialogs = false;
      _startupInProgress = false;
    }
  }

  // Try to startup the device layer
  Future<bool> tryStartup(
    String portString,
    Object? portObject, {
    SerialTransport transport = SerialTransport.serial,
  }) async {
    setState(() {
      _isLoading = true;
    });
    _deviceConnected = false;

    try {
      // Ensure any existing connection is closed before creating a new one
      try {
        await deviceLayer.close();
      } catch (_) {}

      // Create the device layer with the appropriate port
      if ((kIsWeb || kIsWasm) && portObject != null) {
        deviceLayer = DeviceLayer(
          sxiLayer,
          portObject,
          initialBaudRate,
          transport: transport,
          systemConfiguration: _loadedConfig,
          onConnectionDetailChanged: onConnectionDetailsUpdated,
          onMessage: onMessage,
          onError: onDeviceConnectionError,
          onClearMessages: clearAllMessages,
        );
      } else {
        deviceLayer = DeviceLayer(
          sxiLayer,
          portString,
          initialBaudRate,
          transport: transport,
          systemConfiguration: _loadedConfig,
          onConnectionDetailChanged: onConnectionDetailsUpdated,
          onMessage: onMessage,
          onError: onDeviceConnectionError,
          onClearMessages: clearAllMessages,
        );
      }

      // Initialize audio service
      if (!_audioServiceInitialized) {
        logger.i('Initializing AudioService');
        audioServiceHandler = await AudioService.init(
          builder: () => AudioServiceHandler(deviceLayer, appState),
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'com.bp.orbit.channel.audio',
            androidNotificationChannelName: 'Audio Playback',
            androidStopForegroundOnPause: false,
          ),
        );
        logger.i('AudioService was initialized');
        AudioService.asyncError.listen((error) {
          logger.e('AudioService error: $error');
        });
        _audioServiceInitialized = true;
      } else {
        // Re-bind the handler after reconnect so transport controls work
        try {
          audioServiceHandler?.deviceLayer = deviceLayer;
        } catch (_) {}
      }

      final success = await deviceLayer.startupSequence();
      _deviceConnected = success;
      if (!success && mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return success;
    } catch (e) {
      _lastStartupConnectionError = e.toString();
      _deviceConnected = false;
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return false;
    }
  }

  void onConnectionDetailsUpdated(String title, String details) {
    logger.d('Connection details: $details');
    setState(() {
      _connectionDetails = '$title\n$details';
    });
  }

  void onDeviceConnectionError(String details, bool fatal) {
    if (fatal) {
      logger.f('Error: $details');
    } else {
      logger.e('Error: $details');
    }
    if (fatal &&
        !_deviceConnected &&
        details.trim() == 'Device is not initialized') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not connected. Please select a connection.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    if (fatal) {
      if (_suppressFatalConnectionDialogs) {
        _lastStartupConnectionError = details;
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showFatalErrorDialog(context, details);
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(details), duration: const Duration(seconds: 3)),
      );
    }
  }

  void onMessage(
    String title,
    String message, {
    bool snackbar = true,
    bool dismissable = true,
  }) {
    logger.t('onMessage: $title: $message');
    if (snackbar) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$title: $message'),
          duration: const Duration(seconds: 3),
          showCloseIcon: dismissable,
        ),
      );
    } else {
      // For dialogs, check if we already have this warning displayed
      final warningKey = '$title: $message';

      if (_currentlyDisplayedWarnings.contains(warningKey)) {
        logger.d('Warning already displayed, skipping: $warningKey');
        return;
      }

      // Add to tracking set
      _currentlyDisplayedWarnings.add(warningKey);

      showDialog<void>(
        context: context,
        barrierDismissible: dismissable,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: dismissable
                ? <Widget>[
                    TextButton(
                      child: const Text('Ok'),
                      onPressed: () {
                        // Remove from tracking when manually dismissed
                        _currentlyDisplayedWarnings.remove(warningKey);
                        Navigator.of(context).pop();
                      },
                    ),
                  ]
                : [],
          );
        },
      ).then((_) {
        // Remove from tracking if dialog is dismissed by other means
        _currentlyDisplayedWarnings.remove(warningKey);
      });
    }
  }

  Future<void> clearAllMessages({bool onlyPopups = true}) async {
    // Clear all snackbars
    ScaffoldMessenger.of(context).clearSnackBars();

    // Clear the warning tracking set
    _currentlyDisplayedWarnings.clear();

    // Close popup routes that are not setup dialogs
    try {
      final navigator = Navigator.of(context, rootNavigator: true);
      if (onlyPopups) {
        navigator.popUntil((route) {
          if (route is! PopupRoute) return true;

          // Keep setup dialogs open
          final String? name = route.settings.name;
          final bool isSetupDialog = name == _setupDialogRouteUseNativeAux ||
              name == _setupDialogRouteUseAudio ||
              name == _setupDialogRouteSelectAudioDevice;
          return isSetupDialog;
        });
      } else {
        navigator.popUntil((route) => route.isFirst);
      }
      // Allow the navigator to finish pops/animations before proceeding
      try {
        await WidgetsBinding.instance.endOfFrame;
      } catch (_) {}
    } catch (e) {
      logger.w('Error clearing dialogs: $e');
    }
  }

  void _showFatalErrorDialog(BuildContext context, String details) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Connection Error'),
          content: Text(details),
          actions: <Widget>[
            TextButton(
              child: const Text('Retry'),
              onPressed: () async {
                Navigator.of(context).pop();
                if (mounted) {
                  ScaffoldMessenger.of(this.context).clearSnackBars();
                }
                startupSequence();
              },
            ),
            TextButton(
              onPressed: _attemptCloseApp,
              child: const Text('Close App'),
            ),
            TextButton(
              child: const Text('Ignore'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _attemptCloseApp() async {
    // Try to close the app gracefully on supported platforms.
    // On Web/Wasm, just dismiss the dialog.
    try {
      await audioController
          .stopAudioThread()
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      if (!kIsWeb &&
          !kIsWasm &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.macOS)) {
        await windowManager.destroy();
      } else if (!kIsWeb && !kIsWasm) {
        SystemNavigator.pop();
      } else {
        Navigator.of(context, rootNavigator: true).pop();
      }
    } catch (_) {
      // Fallback: close the top-most dialog if any
      try {
        Navigator.of(context, rootNavigator: true).pop();
      } catch (_) {}
    }
  }

  @override
  void onWindowClose() {
    if (_windowCloseInProgress) return;
    _windowCloseInProgress = true;
    unawaited(() async {
      try {
        await audioController
            .stopAudioThread()
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await windowManager.setPreventClose(false);
      } catch (_) {}
      try {
        await windowManager.destroy();
      } catch (_) {}
    }());
  }

  Future<void> setupAudio() async {
    if (!_deviceConnected) {
      logger.d('Skipping audio setup, device not connected');
      return;
    }

    logger.i('Audio setup starting...');

    // Load saved audio preferences
    bool? savedEnableAudio = await appState.storageData.load(
      SaveDataType.enableAudio,
      defaultValue: null,
    );
    final bool? savedUseNativeAuxInput = await appState.storageData.load(
      SaveDataType.useNativeAuxInput,
      defaultValue: null,
    );
    String? savedAudioDeviceName = await appState.storageData.load(
      SaveDataType.lastAudioDevice,
      defaultValue: null,
    );

    bool useAudio;

    // Respect saved selection first (native Aux vs USB audio)
    final isAndroid =
        !kIsWeb && !kIsWasm && defaultTargetPlatform == TargetPlatform.android;

    if (isAndroid && savedUseNativeAuxInput == true) {
      try {
        await audioController.stopAudioThread();
      } catch (_) {}
      appState.updateEnableAudio(false);

      logger.t('Switching to aux...');

      // Switch the head unit to aux now
      try {
        final opened = await HeadUnitAux.switchToAux(timeoutMs: 1500);
        if (!opened) {
          throw StateError('Aux input did not become active');
        }
        onMessage('Head Unit Audio', 'Switched to Aux input.');
        return;
      } catch (e, st) {
        // If native Aux fails, disable it and fall back to USB audio setup
        logger.e('Failed to switch to aux input', error: e, stackTrace: st);
        appState.updateUseNativeAuxInput(false);
        onMessage(
          'Head Unit Audio',
          'Failed to switch to aux input: ${HeadUnitAux.describeError(e)}',
        );
      }
    }

    // If neither audio choice is saved yet, ask about native aux first
    if (isAndroid &&
        savedEnableAudio == null &&
        savedUseNativeAuxInput == null &&
        HeadUnitAux.isAvailable) {
      final useNativeAux = await _showUseNativeAuxDialog();
      if (useNativeAux) {
        appState.updateUseNativeAuxInput(true);
        try {
          await audioController.stopAudioThread();
        } catch (_) {}
        appState.updateEnableAudio(false);

        try {
          final opened = await HeadUnitAux.switchToAux(timeoutMs: 1500);
          if (!opened) throw StateError('Aux input did not become active');
          onMessage('Head Unit Audio', 'Switched to Aux input.');
          return;
        } catch (e, st) {
          logger.e('Failed to switch to aux input', error: e, stackTrace: st);
          appState.updateUseNativeAuxInput(false);
          onMessage(
            'Head Unit Audio',
            'Could not switch to aux input.',
          );
        }
      } else {
        appState.updateUseNativeAuxInput(false);
      }
    }

    // If no saved preference, ask the user
    if (savedEnableAudio == null) {
      logger.d('No saved audio preference; showing dialog');
      useAudio = await _showUseAudioDialog();
      appState.updateEnableAudio(useAudio);
    } else {
      useAudio = savedEnableAudio;
      logger.d('Using saved audio preference: $useAudio');
    }

    if (useAudio) {
      logger.i('Using audio');
      logger.d('Checking microphone permission');
      final granted = await audioController.ensureMicrophonePermission();
      logger.d('Input permission granted: $granted');
      if (!granted) {
        logger.w('Input permission denied, disabling audio...');
        appState.updateEnableAudio(false);
        onMessage(
          'Audio Permission',
          'Microphone permission was denied. Continuing without app audio.',
        );
        return;
      }

      logger.d('Enabling audio');
      appState.updateEnableAudio(true);

      logger.d('Selecting audio device');
      dynamic selectedDevice;
      if (savedAudioDeviceName != null) {
        try {
          var availableDevices =
              await audioController.getAvailableInputDevices();
          for (var device in availableDevices) {
            var deviceName = audioController.getDeviceName(device);
            if (deviceName == savedAudioDeviceName) {
              selectedDevice = device;
              logger.d('Found saved audio device: $deviceName');
              break;
            }
          }
        } catch (e) {
          logger.w('Error finding saved audio device: $e');
        }
      }
      if (selectedDevice == null) {
        selectedDevice = await _showSelectAudioDeviceDialog();
        if (selectedDevice == null) {
          logger.i('Audio device selection dismissed without selection.');
          appState.updateEnableAudio(false);
          unawaited(appState.storageData.save(SaveDataType.enableAudio, false));
          unawaited(appState.storageData.delete(SaveDataType.lastAudioDevice));
          try {
            await audioController.stopAudioThread();
          } catch (_) {}
          onMessage(
            'Audio Input',
            'No input device selected. Continuing without app audio.',
          );
          return;
        }

        var deviceName = audioController.getDeviceName(selectedDevice);
        unawaited(appState.storageData
            .save(SaveDataType.lastAudioDevice, deviceName));
        logger.d('Saved audio device: $deviceName');
      }

      try {
        await audioController.startAudioThread(
          selectedDevice: selectedDevice,
          androidAudioOutputRoute: appState.androidAudioOutputRoute,
          detectAudioInterruptions: appState.detectAudioInterruptions,
          preferredSampleRate: appState.audioSampleRate,
        );
        logger.i('Audio started successfully');
      } catch (e) {
        appState.updateEnableAudio(false);
        onMessage(
          'Audio Error',
          'Failed to start audio: $e. Continuing without app audio.',
        );
      }
    } else {
      appState.updateEnableAudio(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb &&
        !kIsWasm &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      try {
        windowManager.removeListener(this);
      } catch (_) {}
      try {
        unawaited(windowManager.setPreventClose(false));
      } catch (_) {}
    }
    deviceLayer.close();
    audioController.dispose();
    appState.playbackInfoNotifier.removeListener(onPlaybackInfoChanged);
    appState.playbackStateNotifier.removeListener(onPlaybackStateChanged);
    appState.favoriteOnAirNotifier.removeListener(onFavoriteOnAir);
    _onAirShowTimer?.cancel();
    channelTextFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    // Switch head unit to aux when resuming
    if (defaultTargetPlatform != TargetPlatform.android ||
        !HeadUnitAux.isAvailable ||
        !appState.useNativeAuxInput) {
      return;
    }

    final bool isPlaying = appState.playbackState == AppPlaybackState.live ||
        appState.playbackState == AppPlaybackState.recordedContent;

    if (!isPlaying && !appState.audioPresence) return;

    unawaited(HeadUnitAux.trySwitchToAux());
  }

  void onFavoriteOnAir() {
    logger.d('Favorite On Air Event: ${appState.favoriteOnAirNotifier.value}');
    final evt = appState.favoriteOnAirNotifier.value;
    if (!mounted || evt == null) return;

    if (evt.autoAdded) return;

    final key = '${evt.sid}|${evt.matchedId}|${evt.type.name}';
    if (_pendingOnAirKey == key && (_onAirShowTimer?.isActive ?? false)) {
      return;
    }
    _pendingOnAirKey = key;
    _onAirShowTimer?.cancel();
    _onAirShowTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (_pendingOnAirKey != key) return;

      // Ensure the matched favorite is still active and matches the channel
      final channel = appState.sidMap[evt.sid];
      if (channel == null) return;
      final bool matchesChannel = (evt.type == FavoriteType.song)
          ? (channel.airingSongId == evt.matchedId && channel.airingSongId != 0)
          : (channel.airingArtistId == evt.matchedId &&
              channel.airingArtistId != 0);
      if (!matchesChannel) return;

      _lastOnAirPromptAt = DateTime.now();
      setState(() {});

      // Schedule hide after 20 seconds unless a newer event arrives
      Future.delayed(const Duration(seconds: 20), () {
        if (!mounted) return;
        if (_lastOnAirPromptAt != null &&
            DateTime.now().difference(_lastOnAirPromptAt!) >=
                const Duration(seconds: 20)) {
          setState(() {
            _lastOnAirPromptAt = null;
          });
        }
      });
    });
  }

  // Update the playback info
  void onPlaybackInfoChanged() {
    if (_isLoading) {
      setState(() {
        _isLoading = false;
      });
    }
    var playbackInfo = appState.nowPlaying;

    setState(() {
      channelTextController.text = playbackInfo.channelNumber.toString();
    });

    if (appState.lastSid != playbackInfo.sid) {
      appState.updateLastSid(playbackInfo.sid);
    }

    if (playbackInfo.channelImage.isNotEmpty) {
      try {
        currentChannelImage = Image.memory(
          playbackInfo.channelImage,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
        );
      } catch (e) {
        logger.w('Error loading channel image: $e');
        currentChannelImage = null;
      }
    } else {
      currentChannelImage = null;
    }

    updateTransport();
    audioServiceHandler?.onPlaybackInfoChanged(playbackInfo);
  }

  // Update the playback state
  void onPlaybackStateChanged() {
    updateTransport();
    audioServiceHandler?.onPlaybackStateChanged(appState.playbackState);
  }

  // Update the transport
  void updateTransport() {
    if (appState.playbackState != AppPlaybackState.live &&
        !transportDragging &&
        !appState.isTuneMixActive) {
      var total = appState.playbackTimeBefore + appState.playbackTimeRemaining;

      if (total != 0) {
        transportValue = (appState.playbackTimeBefore / total);
      }

      if (transportValue < 0) {
        transportValue = 0;
      }
    }
  }

  // Show the EPG dialog
  Future<int> _showSelectChannelFromEPG({int? initialCategory}) async {
    return await EpgDialogHelper.showEpgDialog(
      context: context,
      appState: appState,
      sxiLayer: sxiLayer,
      deviceLayer: deviceLayer,
      initialCategory: initialCategory,
      mainScrollController: mainScrollController,
      mainListController: mainListController,
      categoryScrollController: categoryScrollController,
      categoryListController: categoryListController,
    );
  }

  // Show the head unit native aux dialog (Android first-time setup)
  Future<bool> _showUseNativeAuxDialog() async {
    return await showDialog<bool>(
          barrierDismissible: false,
          context: context,
          routeSettings:
              const RouteSettings(name: _setupDialogRouteUseNativeAux),
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Head Unit Audio'),
              content: const Text(
                'If you have a supported head unit, Orbit can try to switch the head unit to Aux-in.',
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('No, use USB audio'),
                  onPressed: () {
                    Navigator.pop(context, false);
                  },
                ),
                FilledButton(
                  child: const Text('Yes, use Aux'),
                  onPressed: () {
                    Navigator.pop(context, true);
                  },
                ),
              ],
            );
          },
        ) ??
        false;
  }

  // Show the use audio dialog
  Future<bool> _showUseAudioDialog() async {
    return await showDialog<bool>(
          barrierDismissible: false,
          context: context,
          routeSettings: const RouteSettings(name: _setupDialogRouteUseAudio),
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Audio Playback'),
              content: const Text(
                'Do you want to use this app for audio playback?\n\nThis will capture audio from an input device and play it through your speakers.',
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('No'),
                  onPressed: () {
                    Navigator.pop(context, false);
                  },
                ),
                TextButton(
                  child: const Text('Yes'),
                  onPressed: () {
                    Navigator.pop(context, true);
                  },
                ),
              ],
            );
          },
        ) ??
        false;
  }

  // Show the select audio device dialog
  Future<dynamic> _showSelectAudioDeviceDialog() async {
    List<dynamic> availableDevices = [];
    List<String> deviceNames = [];

    // Define loaders outside the dialog's builder so they are not recreated on every rebuild
    Future<List<String>> loadDevices() async {
      try {
        // Get the available input devices
        availableDevices = await audioController.getAvailableInputDevices();
        deviceNames.clear();
        for (var device in availableDevices) {
          var deviceName = audioController.getDeviceName(device);
          deviceNames.add(deviceName);
        }
        return deviceNames;
      } catch (e) {
        logger.w('Error loading audio devices: $e');
        return ['Error loading devices'];
      }
    }

    // Keep the same Future instance across rebuilds
    Future<List<String>> devicesFuture = loadDevices();

    return await showDialog<dynamic>(
      barrierDismissible: false,
      context: context,
      routeSettings:
          const RouteSettings(name: _setupDialogRouteSelectAudioDevice),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateDialog) {
            return AlertDialog(
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Select Audio Input Device'),
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
                    tooltip: 'Skip',
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
                    deviceNames = snapshot.data ?? [];
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: deviceNames.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          title: Text(deviceNames[index]),
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
  }

  Future<(SerialTransport, String, Object?)> _promptForConnection({
    String? previousNetworkSpec,
    bool canDismissSerial = false,
    bool barrierDismissible = false,
    String? message,
  }) async {
    while (true) {
      final SerialTransport? transport =
          await ConnectionDialogs.showConnectionType(
        context,
        barrierDismissible: barrierDismissible,
        message: message,
      );
      if (!mounted) {
        return (SerialTransport.serial, '', null);
      }
      if (transport == null) {
        return (SerialTransport.serial, '', null);
      }
      if (transport == SerialTransport.network && !kIsWeb && !kIsWasm) {
        final String? spec = await ConnectionDialogs.showNetworkConfig(context);
        if (!mounted) {
          return (SerialTransport.serial, '', null);
        }
        if (spec == null) {
          continue;
        }
        return (SerialTransport.network, spec, null);
      } else if (transport == SerialTransport.serial) {
        final (String, Object?) res = await ConnectionDialogs.selectSerialPort(
          context,
          serialHelper: serialHelper,
          storageData: appState.storageData,
          canDismiss: canDismissSerial,
        );
        if (!mounted) {
          return (SerialTransport.serial, '', null);
        }
        if (res.$1.isEmpty && res.$2 == null) {
          continue;
        }
        return (SerialTransport.serial, res.$1, res.$2);
      } else {
        return (SerialTransport.serial, '', null);
      }
    }
  }

  // Build the text that may show in the app bar
  Widget _buildAppBarTitle(BuildContext context, AppState appState) {
    // If any favorites are on air, show a centered quick-access button
    if (appState.showOnAirFavoritesPrompt &&
        appState.favoritesOnAirEntries.isNotEmpty &&
        _lastOnAirPromptAt != null) {
      final hasSong = appState.favoritesOnAirEntries
          .any((e) => e.type == FavoriteType.song);
      final bool smallPortrait =
          appState.smallScreenMode && !isLandscape(context);
      final label = smallPortrait
          ? 'Fav ${hasSong ? 'Song' : 'Artist'}'
          : 'Favorite ${hasSong ? 'Song' : 'Artist'} On Air';
      final colorScheme = Theme.of(context).colorScheme;
      return TextButton.icon(
        onPressed: () {
          // Hide the alert and end any pending timers
          _onAirShowTimer?.cancel();
          _pendingOnAirKey = null;
          setState(() {
            _lastOnAirPromptAt = null;
          });

          FavoritesOnAirDialogHelper.show(
            context: context,
            appState: appState,
            deviceLayer: deviceLayer,
          );
        },
        icon: Icon(Icons.favorite, color: colorScheme.primary),
        label: Text(
          label,
          style: TextStyle(color: colorScheme.primary),
        ),
      );
    }
    if (appState.updatingCategories || appState.updatingChannels) {
      return Text(
        'Updating ${appState.updatingChannels ? 'Channels' : 'Categories'}...',
      );
    }
    if (appState.isScanActive) {
      return Text('Scanning Presets...');
    }
    if (appState.isTuneMixActive) {
      return Text('Presets Mix');
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        final int activePresets =
            appState.presets.where((p) => p.sid != 0).length;
        final bool bigAppBar = appState.smallScreenMode && isLandscape(context);
        return Stack(
          children: [
            Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                toolbarHeight: bigAppBar ? 76 : kToolbarHeight,
                title: _buildAppBarTitle(context, appState),
                centerTitle: true,
                leading: IconButton(
                  icon: Icon(getSignalIcon(
                    appState.signalQuality,
                    isAntennaConnected: appState.isAntennaConnected,
                  )),
                  iconSize: bigAppBar ? 32 : 24,
                  padding: EdgeInsets.all(bigAppBar ? 14 : 8),
                  constraints: BoxConstraints(
                    minWidth: bigAppBar ? 64 : 48,
                    minHeight: bigAppBar ? 64 : 48,
                  ),
                  tooltip: appState.isAntennaConnected
                      ? 'Signal quality'
                      : 'No antenna',
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) =>
                          SignalQualityDialog(deviceLayer: deviceLayer),
                    );
                  },
                ),
                actions: [
                  if (appState.smallScreenMode) ...[
                    IconButton(
                      tooltip: appState.isScanActive
                          ? 'Stop and Listen'
                          : (activePresets >= 2
                              ? 'Scan Presets'
                              : 'Not Enough Presets'),
                      icon: Icon(
                        appState.isScanActive ? Icons.close : Icons.scanner,
                      ),
                      iconSize: bigAppBar ? 30 : 24,
                      padding: EdgeInsets.all(bigAppBar ? 14 : 8),
                      constraints: BoxConstraints(
                        minWidth: bigAppBar ? 64 : 48,
                        minHeight: bigAppBar ? 64 : 48,
                      ),
                      onPressed: (appState.isScanActive || activePresets >= 2)
                          ? () {
                              if (appState.isScanActive) {
                                final cfgCmd = SXiSelectChannelCommand(
                                  ChanSelectionType
                                      .stopScanAndContinuePlaybackOfCurrentTrack,
                                  0,
                                  appState.currentCategory,
                                  ChannelAttributes.all(),
                                  AudioRoutingType.routeToAudio,
                                );
                                deviceLayer.sendControlCommand(cfgCmd);
                              } else {
                                final cfgCmd = SXiSelectChannelCommand(
                                  ChanSelectionType
                                      .scanSmartFavoriteMusicOnlyContent,
                                  0,
                                  appState.currentCategory,
                                  ChannelAttributes.all(),
                                  AudioRoutingType.routeToAudio,
                                );
                                deviceLayer.sendControlCommand(cfgCmd);
                              }
                            }
                          : null,
                    ),
                    IconButton(
                      tooltip: appState.updatingChannels
                          ? 'Channel Update in Progress'
                          : 'Program Guide',
                      icon: const Icon(Icons.view_list),
                      iconSize: bigAppBar ? 30 : 24,
                      padding: EdgeInsets.all(bigAppBar ? 14 : 8),
                      constraints: BoxConstraints(
                        minWidth: bigAppBar ? 64 : 48,
                        minHeight: bigAppBar ? 64 : 48,
                      ),
                      onPressed: appState.updatingChannels
                          ? null
                          : () {
                              _showSelectChannelFromEPG();
                            },
                    ),
                    IconButton(
                      tooltip: appState.isTuneMixActive
                          ? 'Stop Mix'
                          : (activePresets >= 2
                              ? 'Start Presets Mix'
                              : 'Not Enough Presets'),
                      icon: Icon(
                        appState.isTuneMixActive ? Icons.close : Icons.shuffle,
                      ),
                      iconSize: bigAppBar ? 30 : 24,
                      padding: EdgeInsets.all(bigAppBar ? 14 : 8),
                      constraints: BoxConstraints(
                        minWidth: bigAppBar ? 64 : 48,
                        minHeight: bigAppBar ? 64 : 48,
                      ),
                      onPressed:
                          (appState.isTuneMixActive || activePresets >= 2)
                              ? () {
                                  if (appState.isTuneMixActive) {
                                    final cfgCmd = SXiSelectChannelCommand(
                                      ChanSelectionType.tuneUsingChannelNumber,
                                      appState.currentChannel,
                                      appState.currentCategory,
                                      ChannelAttributes.all(),
                                      AudioRoutingType.routeToAudio,
                                    );
                                    deviceLayer.sendControlCommand(cfgCmd);
                                  } else {
                                    final cfgCmd = SXiSelectChannelCommand(
                                      ChanSelectionType.tuneUsingSID,
                                      0x1001,
                                      appState.currentCategory,
                                      ChannelAttributes.all(),
                                      AudioRoutingType.routeToAudio,
                                    );
                                    deviceLayer.sendControlCommand(cfgCmd);
                                  }
                                }
                              : null,
                    ),
                  ],
                  IconButton(
                    icon: const Icon(Icons.settings),
                    iconSize: bigAppBar ? 30 : 24,
                    padding: EdgeInsets.all(bigAppBar ? 14 : 8),
                    constraints: BoxConstraints(
                      minWidth: bigAppBar ? 64 : 48,
                      minHeight: bigAppBar ? 64 : 48,
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => SettingsPage(mainPage: this),
                        ),
                      );
                    },
                  ),
                ],
              ),
              body: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isLandscapeMode = isLandscape(context);

                      if (isLandscapeMode) {
                        return Column(
                          children: [
                            Expanded(
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      maxWidth: appState.smallScreenMode
                                          ? constraints.maxWidth
                                          : 700),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      // Channel info
                                      () {
                                        final bool smallLandscape =
                                            appState.smallScreenMode;
                                        final Widget channelCenter =
                                            GestureDetector(
                                          onTap: () {
                                            ChannelInfoDialog.show(
                                              context,
                                              appState: appState,
                                              sid: appState.currentSid,
                                              deviceLayer: deviceLayer,
                                              onTuneAlign: (channelNumber) {
                                                // Tune to the channel
                                                final cfgCmd =
                                                    SXiSelectChannelCommand(
                                                  ChanSelectionType
                                                      .tuneUsingChannelNumber,
                                                  channelNumber,
                                                  0xFF,
                                                  ChannelAttributes.all(),
                                                  AudioRoutingType.routeToAudio,
                                                );
                                                deviceLayer
                                                    .sendControlCommand(cfgCmd);
                                              },
                                            );
                                          },
                                          child: currentChannelImage != null
                                              ? ConstrainedBox(
                                                  constraints:
                                                      const BoxConstraints(
                                                    maxWidth: 400,
                                                    maxHeight: 60,
                                                  ),
                                                  child: currentChannelImage!,
                                                )
                                              : ConstrainedBox(
                                                  constraints:
                                                      const BoxConstraints(
                                                    maxWidth: 400,
                                                    maxHeight: 60,
                                                  ),
                                                  child: Text(
                                                    appState
                                                        .nowPlaying.channelName,
                                                    textAlign: TextAlign.center,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: appState
                                                              .smallScreenMode
                                                          ? 20
                                                          : 32,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                        );

                                        if (!smallLandscape) {
                                          return channelCenter;
                                        }

                                        return Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            _buildChannelBrowseButton(
                                                left: true),
                                            const SizedBox(width: 10),
                                            _buildChannelNumberInput(
                                                bigControls: true),
                                            const SizedBox(width: 20),
                                            channelCenter,
                                            const SizedBox(width: 10),
                                            _buildChannelBrowseButton(
                                                left: false),
                                          ],
                                        );
                                      }(),

                                      SizedBox(
                                          height: appState.smallScreenMode
                                              ? 16
                                              : 40),
                                      // Main content: Album art + info
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          // Album Art
                                          GestureDetector(
                                            onTap: () {
                                              FavoriteDialogHelper.show(
                                                context: context,
                                                appState: appState,
                                                deviceLayer: deviceLayer,
                                              );
                                            },
                                            child: AlbumArt(
                                              size: appState.smallScreenMode
                                                  ? 140
                                                  : 180,
                                              filterQuality: FilterQuality.high,
                                              imageBytes: appState
                                                      .nowPlaying.image.isEmpty
                                                  ? null
                                                  : appState.nowPlaying.image,
                                              borderRadius: 8.0,
                                              borderWidth: 2.0,
                                              placeholder: Icon(
                                                getCategoryIcon(
                                                  appState
                                                      .currentCategoryString,
                                                ),
                                                size: 64,
                                              ),
                                            ),
                                          ),
                                          SizedBox(width: 36),
                                          // Song Info
                                          Flexible(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.center,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                TextButton(
                                                  onPressed: () {
                                                    _showSelectChannelFromEPG(
                                                      initialCategory: appState
                                                          .currentCategory,
                                                    );
                                                  },
                                                  child: Text(
                                                    appState
                                                        .currentCategoryString,
                                                    style:
                                                        TextStyle(fontSize: 20),
                                                  ),
                                                ),
                                                SizedBox(height: 8),
                                                GestureDetector(
                                                  onTap: () {
                                                    FavoriteDialogHelper.show(
                                                      context: context,
                                                      appState: appState,
                                                      deviceLayer: deviceLayer,
                                                    );
                                                  },
                                                  child: Text(
                                                    appState
                                                        .nowPlaying.songTitle,
                                                    style: TextStyle(
                                                      fontSize: 28,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                    maxLines:
                                                        appState.smallScreenMode
                                                            ? 1
                                                            : 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    textAlign: TextAlign.center,
                                                  ),
                                                ),
                                                SizedBox(height: 8),
                                                GestureDetector(
                                                  onTap: () {
                                                    FavoriteDialogHelper.show(
                                                      context: context,
                                                      appState: appState,
                                                      deviceLayer: deviceLayer,
                                                    );
                                                  },
                                                  child: Text(
                                                    appState
                                                        .nowPlaying.artistTitle,
                                                    style: TextStyle(
                                                      fontSize: 20,
                                                      color: Colors.grey,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    textAlign: TextAlign.center,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      SizedBox(
                                          height: appState.smallScreenMode
                                              ? 16
                                              : 40),
                                      // Channel and Playback in one row
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: appState.smallScreenMode
                                            ? <Widget>[
                                                _buildPlaybackControls(),
                                              ]
                                            : <Widget>[
                                                // Channel Controls
                                                _buildChannelControls(),
                                                SizedBox(width: 32),
                                                // Vertical Separator
                                                Container(
                                                  width: 1,
                                                  height: 60,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .outline
                                                      .withValues(alpha: 0.3),
                                                ),
                                                SizedBox(width: 32),
                                                // Playback Controls
                                                _buildPlaybackControls(),
                                              ],
                                      ),
                                      if (!appState.smallScreenMode) ...[
                                        const SizedBox(height: 12),
                                        // Contextual actions
                                        _buildActionButtons(isLandscape: true),
                                      ],
                                      if (!appState.smallScreenMode)
                                        const SizedBox(height: 12),
                                      _buildTransportArea(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            // Contextual actions row
                            // Preset carousel at bottom
                            SizedBox(
                              height: 140,
                              child: PresetCarousel(
                                key: presetCarouselKey,
                                presets: appState.presets,
                                currentSid: appState.currentSid,
                                logoProvider: (sid) {
                                  final bytes =
                                      appState.storageData.getImageForSid(sid);
                                  if (bytes.isEmpty) return null;
                                  return Uint8List.fromList(bytes);
                                },
                                categoryNameProvider: (sid) {
                                  final channel = appState.sidMap[sid];
                                  if (channel == null) return '';
                                  return appState.categories[channel.catId] ??
                                      '';
                                },
                                onPresetTap: (sid) {
                                  final cfgCmd = SXiSelectChannelCommand(
                                    ChanSelectionType.tuneUsingSID,
                                    sid,
                                    0xFF,
                                    ChannelAttributes.all(),
                                    AudioRoutingType.routeToAudio,
                                  );
                                  deviceLayer.sendControlCommand(cfgCmd);
                                },
                                onPresetLongPress: onPresetLongPress,
                              ),
                            ),
                          ],
                        );
                      } else {
                        // Portrait layout (original)
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Current Channel Name or Image
                            SizedBox(
                              height: 35,
                              width: 300,
                              child: GestureDetector(
                                onTap: () {
                                  ChannelInfoDialog.show(
                                    context,
                                    appState: appState,
                                    sid: appState.currentSid,
                                    deviceLayer: deviceLayer,
                                    onTuneAlign: (channelNumber) {
                                      // Tune to the channel
                                      final cfgCmd = SXiSelectChannelCommand(
                                        ChanSelectionType
                                            .tuneUsingChannelNumber,
                                        channelNumber,
                                        0xFF,
                                        ChannelAttributes.all(),
                                        AudioRoutingType.routeToAudio,
                                      );
                                      deviceLayer.sendControlCommand(cfgCmd);
                                    },
                                  );
                                },
                                child: currentChannelImage ??
                                    Text(
                                      appState.nowPlaying.channelName,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                              ),
                            ),

                            // Current Channel Category
                            TextButton(
                              onPressed: () {
                                _showSelectChannelFromEPG(
                                  initialCategory: appState.currentCategory,
                                );
                              },
                              child: Text(
                                appState.currentCategoryString,
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Current track album art
                            GestureDetector(
                              onTap: () {
                                FavoriteDialogHelper.show(
                                  context: context,
                                  appState: appState,
                                  deviceLayer: deviceLayer,
                                );
                              },
                              child: AlbumArt(
                                size: 128,
                                filterQuality: FilterQuality.high,
                                imageBytes: appState.nowPlaying.image.isEmpty
                                    ? null
                                    : appState.nowPlaying.image,
                                borderRadius: 8.0,
                                borderWidth: 2.0,
                                placeholder: Icon(
                                  getCategoryIcon(
                                      appState.currentCategoryString),
                                  size: 44,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Current track
                            GestureDetector(
                              onTap: () {
                                FavoriteDialogHelper.show(
                                  context: context,
                                  appState: appState,
                                  deviceLayer: deviceLayer,
                                );
                              },
                              child: Text(
                                appState.nowPlaying.songTitle,
                                style: TextStyle(fontSize: 20),
                                maxLines: appState.smallScreenMode ? 1 : null,
                                overflow: appState.smallScreenMode
                                    ? TextOverflow.ellipsis
                                    : null,
                              ),
                            ),
                            // Current artist
                            GestureDetector(
                              onTap: () {
                                FavoriteDialogHelper.show(
                                  context: context,
                                  appState: appState,
                                  deviceLayer: deviceLayer,
                                );
                              },
                              child: Text(
                                appState.nowPlaying.artistTitle,
                                style:
                                    TextStyle(fontSize: 18, color: Colors.grey),
                                maxLines: appState.smallScreenMode ? 1 : null,
                                overflow: appState.smallScreenMode
                                    ? TextOverflow.ellipsis
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 10),
                            //  Playback controls
                            _buildPlaybackControls(),
                            //  Channel control
                            _buildChannelControls(),
                            if (!appState.smallScreenMode) ...[
                              const SizedBox(height: 10),
                              _buildActionButtons(isLandscape: false),
                            ],
                            _buildTransportArea(),
                            Expanded(
                              child: PresetCarousel(
                                key: presetCarouselKey,
                                presets: appState.presets,
                                currentSid: appState.currentSid,
                                logoProvider: (sid) {
                                  final bytes =
                                      appState.storageData.getImageForSid(
                                    sid,
                                  );
                                  if (bytes.isEmpty) return null;
                                  return Uint8List.fromList(bytes);
                                },
                                categoryNameProvider: (sid) {
                                  final channel = appState.sidMap[sid];
                                  if (channel == null) return '';
                                  return appState.categories[channel.catId] ??
                                      '';
                                },
                                onPresetTap: (sid) {
                                  final cfgCmd = SXiSelectChannelCommand(
                                    ChanSelectionType.tuneUsingSID,
                                    sid,
                                    0xFF,
                                    ChannelAttributes.all(),
                                    AudioRoutingType.routeToAudio,
                                  );
                                  deviceLayer.sendControlCommand(cfgCmd);
                                },
                                onPresetLongPress: onPresetLongPress,
                              ),
                            ),
                          ],
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
            if (_isLoading)
              Container(
                color: Colors.black54,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 20),
                      Text(
                        _connectionDetails,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontSize: 18,
                                ) ??
                            const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                    ],
                  ),
                ),
              ),
            if (_startupGateVisible)
              Positioned.fill(
                child: Stack(
                  children: [
                    const ModalBarrier(
                      dismissible: false,
                      color: Colors.black54,
                    ),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Connection Required',
                                  style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ) ??
                                      const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _startupGateMessage.isEmpty
                                      ? 'Connect to a device to continue.'
                                      : _startupGateMessage,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _openSettings,
                                      icon: const Icon(Icons.settings),
                                      label: const Text('Settings'),
                                    ),
                                    const SizedBox(width: 12),
                                    FilledButton.icon(
                                      onPressed: _connectFromStartupGate,
                                      icon: const Icon(Icons.cable),
                                      label: const Text('Connect'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  void onPresetLongPress(int presetIndex) {
    final int currentSid = appState.nowPlaying.sid;
    final bool isSlotFilled = appState.presets[presetIndex].sid != 0;

    if (isSlotFilled) {
      // If the slot already contains the currently playing channel, just open the editor
      if (currentSid != 0 && appState.presets[presetIndex].sid == currentSid) {
        PresetsEditorDialogHelper.show(
          context: context,
          appState: appState,
          mainPage: this,
        );
        return;
      }

      // Otherwise, ask how to modify it
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('How do you want to modify this preset?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                PresetsEditorDialogHelper.show(
                  context: context,
                  appState: appState,
                  mainPage: this,
                );
              },
              child: const Text('Edit'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                if (currentSid == 0) {
                  return;
                }

                final int existingIndex =
                    appState.presets.indexWhere((p) => p.sid == currentSid);
                if (existingIndex != -1 && existingIndex != presetIndex) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Preset already exists'),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                  presetCarouselKey.currentState?.navigateToPreset(currentSid);
                  return;
                }

                setState(() {
                  appState.presets[presetIndex]
                      .setFromPlaybackInfo(appState.nowPlaying);
                });
                sendPresets();
              },
              child: const Text('Replace'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      return;
    }

    // Empty slot, try to add the current channel
    final int existingIndex =
        appState.presets.indexWhere((p) => p.sid == currentSid);
    if (existingIndex != -1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Preset already exists'),
          duration: const Duration(seconds: 3),
        ),
      );
      presetCarouselKey.currentState?.navigateToPreset(currentSid);
      return;
    }

    setState(() {
      appState.presets[presetIndex].setFromPlaybackInfo(appState.nowPlaying);
    });
    sendPresets();
  }

  String formatDuration(int totalSeconds) {
    final duration = Duration(seconds: totalSeconds);
    String twoDigits(int n) => n.toString().padLeft(2, '0');

    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours == 0) {
      // Under 1 hour, show MM:SS with zero-padding
      return '${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    // 1 hour or more, show HH:MM:SS with zero-padding
    return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  Widget _buildActionButtons({required bool isLandscape}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final double buttonHeight = 40;
    final EdgeInsetsGeometry padding = isLandscape
        ? const EdgeInsets.symmetric(horizontal: 48)
        : const EdgeInsets.symmetric(horizontal: 12);
    final int activePresets = appState.presets.where((p) => p.sid != 0).length;

    return Padding(
      padding: padding,
      child: Row(
        children: [
          // Scan
          Expanded(
            child: Tooltip(
              message: appState.isScanActive
                  ? 'Stop and Listen'
                  : (activePresets >= 2
                      ? 'Scan Presets'
                      : 'Not Enough Presets'),
              child: SizedBox(
                height: buttonHeight,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size.fromHeight(buttonHeight),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    backgroundColor: appState.isScanActive
                        ? cs.primaryContainer
                        : cs.surfaceContainer,
                    foregroundColor: (appState.isScanActive ||
                            (appState.isScanActive || activePresets >= 2))
                        ? (appState.isScanActive
                            ? cs.onPrimaryContainer
                            : cs.onSurface)
                        : cs.onSurfaceVariant,
                    side: BorderSide(
                      color: appState.isScanActive
                          ? cs.primary
                          : cs.outline.withValues(alpha: 0.3),
                      width: appState.isScanActive ? 2.0 : 1.0,
                    ),
                  ).copyWith(
                    overlayColor: WidgetStatePropertyAll(
                      cs.primary.withValues(alpha: 0.08),
                    ),
                  ),
                  onPressed: (appState.isScanActive || activePresets >= 2)
                      ? () {
                          if (appState.isScanActive) {
                            final cfgCmd = SXiSelectChannelCommand(
                              ChanSelectionType
                                  .stopScanAndContinuePlaybackOfCurrentTrack,
                              0,
                              appState.currentCategory,
                              ChannelAttributes.all(),
                              AudioRoutingType.routeToAudio,
                            );
                            deviceLayer.sendControlCommand(cfgCmd);
                          } else {
                            final cfgCmd = SXiSelectChannelCommand(
                              ChanSelectionType
                                  .scanSmartFavoriteMusicOnlyContent,
                              0,
                              appState.currentCategory,
                              ChannelAttributes.all(),
                              AudioRoutingType.routeToAudio,
                            );
                            deviceLayer.sendControlCommand(cfgCmd);
                          }
                        }
                      : null,
                  icon: appState.isScanActive
                      ? const Icon(Icons.close)
                      : const Icon(Icons.scanner),
                  label: const Text('Scan'),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // EPG
          Expanded(
            child: Tooltip(
              message: appState.updatingChannels
                  ? 'Channel Update in Progress'
                  : 'Program Guide',
              child: SizedBox(
                height: buttonHeight,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size.fromHeight(buttonHeight),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    backgroundColor: cs.surfaceContainer,
                    foregroundColor: cs.onSurface,
                    side: BorderSide(
                      color: cs.outline.withValues(alpha: 0.3),
                      width: 1.0,
                    ),
                  ).copyWith(
                    overlayColor: WidgetStatePropertyAll(
                      cs.primary.withValues(alpha: 0.08),
                    ),
                  ),
                  onPressed: appState.updatingChannels
                      ? null
                      : () {
                          _showSelectChannelFromEPG();
                        },
                  icon: const Icon(Icons.view_list),
                  label: const Text('Guide'),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Mix
          Expanded(
            child: Tooltip(
              message: appState.isTuneMixActive
                  ? 'Stop Mix'
                  : (activePresets >= 2
                      ? 'Start Presets Mix'
                      : 'Not Enough Presets'),
              child: SizedBox(
                height: buttonHeight,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size.fromHeight(buttonHeight),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    backgroundColor: appState.isTuneMixActive
                        ? cs.primaryContainer
                        : cs.surfaceContainer,
                    foregroundColor: (appState.isTuneMixActive ||
                            (appState.isTuneMixActive || activePresets >= 2))
                        ? (appState.isTuneMixActive
                            ? cs.onPrimaryContainer
                            : cs.onSurface)
                        : cs.onSurfaceVariant,
                    side: BorderSide(
                      color: appState.isTuneMixActive
                          ? cs.primary
                          : cs.outline.withValues(alpha: 0.3),
                      width: appState.isTuneMixActive ? 2.0 : 1.0,
                    ),
                  ).copyWith(
                    overlayColor: WidgetStatePropertyAll(
                      cs.primary.withValues(alpha: 0.08),
                    ),
                  ),
                  onPressed: (appState.isTuneMixActive || activePresets >= 2)
                      ? () {
                          if (appState.isTuneMixActive) {
                            final cfgCmd = SXiSelectChannelCommand(
                              ChanSelectionType.tuneUsingChannelNumber,
                              appState.currentChannel,
                              appState.currentCategory,
                              ChannelAttributes.all(),
                              AudioRoutingType.routeToAudio,
                            );
                            deviceLayer.sendControlCommand(cfgCmd);
                          } else {
                            final cfgCmd = SXiSelectChannelCommand(
                              ChanSelectionType.tuneUsingSID,
                              0x1001,
                              appState.currentCategory,
                              ChannelAttributes.all(),
                              AudioRoutingType.routeToAudio,
                            );
                            deviceLayer.sendControlCommand(cfgCmd);
                          }
                        }
                      : null,
                  icon: appState.isTuneMixActive
                      ? const Icon(Icons.close)
                      : const Icon(Icons.shuffle),
                  label: const Text('Mix'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Build the playback controls
  Widget _buildPlaybackControls() {
    final bool small = appState.smallScreenMode;
    final bool bigControls = small && isLandscape(context);
    final double favoriteIconSize = bigControls ? 36 : 28;
    final double transportIconSize = bigControls ? 54 : 36;
    final EdgeInsetsGeometry iconPadding = EdgeInsets.all(bigControls ? 14 : 8);
    final BoxConstraints iconConstraints = BoxConstraints(
      minWidth: bigControls ? 64 : 48,
      minHeight: bigControls ? 64 : 48,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (!appState.isScanActive) ...[
          // Favorite toggle button
          IconButton(
            tooltip: 'Favorite',
            iconSize: favoriteIconSize,
            padding: iconPadding,
            constraints: iconConstraints,
            icon: Icon(
              appState.isNowPlayingSongFavorited() ||
                      appState.isNowPlayingArtistFavorited()
                  ? Icons.favorite
                  : Icons.favorite_border,
            ),
            color: appState.isNowPlayingSongFavorited() ||
                    appState.isNowPlayingArtistFavorited()
                ? Theme.of(context).colorScheme.primary
                : null,
            onPressed: () {
              FavoriteDialogHelper.show(
                context: context,
                appState: appState,
                deviceLayer: deviceLayer,
              );
            },
          ),
          const SizedBox(width: 8),
        ],
        // Rev button
        IconButton(
          icon: const Icon(Icons.skip_previous),
          iconSize: transportIconSize,
          padding: iconPadding,
          constraints: iconConstraints,
          onPressed: () {
            audioServiceHandler?.rewind();
          },
        ),

        // Play/Pause button (only for regular listening and TuneMix)
        if (!appState.isScanActive)
          IconButton(
            icon: Icon(
              appState.playbackState == AppPlaybackState.paused ||
                      appState.playbackState == AppPlaybackState.stopped
                  ? Icons.play_arrow
                  : Icons.pause,
            ),
            iconSize: transportIconSize,
            padding: iconPadding,
            constraints: iconConstraints,
            onPressed: () {
              if (appState.playbackState == AppPlaybackState.paused ||
                  appState.playbackState == AppPlaybackState.stopped) {
                audioServiceHandler?.play();
              } else {
                audioServiceHandler?.pause();
              }
            },
          ),

        // Forward button
        IconButton(
          icon: const Icon(Icons.skip_next),
          iconSize: transportIconSize,
          padding: iconPadding,
          constraints: iconConstraints,
          onPressed: appState.playbackState == AppPlaybackState.live
              ? null
              : () {
                  audioServiceHandler?.fastForward();
                },
        ),

        // State-specific buttons
        if (appState.isScanActive) ...[
          // Scan mode, Stop and Listen
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: Size(bigControls ? 92 : 64, bigControls ? 64 : 48),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            onPressed: () {
              final cfgCmd = SXiSelectChannelCommand(
                ChanSelectionType
                    .abortScanAndResumePlaybackOfItemActiveAtScanInitiation,
                0,
                appState.currentCategory,
                ChannelAttributes.all(),
                AudioRoutingType.routeToAudio,
              );
              deviceLayer.sendControlCommand(cfgCmd);
            },
            child: Text('Stop &\nGo Back', textAlign: TextAlign.center),
          ),
        ] else if (appState.isTuneMixActive) ...[
          // TuneMix mode, Last Listened
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: Size(bigControls ? 92 : 64, bigControls ? 64 : 48),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            onPressed: appState.playbackState == AppPlaybackState.live
                ? null
                : () {
                    audioServiceHandler?.goToLive();
                  },
            child: Text('Last\nListened', textAlign: TextAlign.center),
          ),
        ] else ...[
          // Regular listening mode, LIVE
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: Size(bigControls ? 92 : 64, bigControls ? 64 : 48),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            onPressed: appState.playbackState == AppPlaybackState.live
                ? null
                : () {
                    audioServiceHandler?.goToLive();
                  },
            child: Text('LIVE', textAlign: TextAlign.center),
          ),
        ],
      ],
    );
  }

  Widget _buildChannelBrowseButton({required bool left}) {
    final bool bigControls = appState.smallScreenMode && isLandscape(context);
    final double iconSize = bigControls ? 40 : 24;
    final EdgeInsetsGeometry padding = EdgeInsets.all(bigControls ? 14 : 8);
    final BoxConstraints constraints = BoxConstraints(
      minWidth: bigControls ? 64 : 48,
      minHeight: bigControls ? 64 : 48,
    );

    return IconButton(
      tooltip: left ? 'Previous channel' : 'Next channel',
      iconSize: iconSize,
      padding: padding,
      constraints: constraints,
      icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
      onPressed: () {
        final cfgCmd = SXiSelectChannelCommand(
          left
              ? ChanSelectionType.tuneToNextLowerChannelNumberInCategory
              : ChanSelectionType.tuneToNextHigherChannelNumberInCategory,
          appState.nowPlaying.channelNumber,
          0xFF,
          ChannelAttributes.all(),
          AudioRoutingType.routeToAudio,
        );
        deviceLayer.sendControlCommand(cfgCmd);
      },
    );
  }

  Widget _buildChannelNumberInput({required bool bigControls}) {
    final double textFieldWidth = bigControls ? 92.0 : 100.0;
    final double? controlHeight = bigControls ? 64.0 : null;

    final inputDecoration = bigControls
        ? const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10),
          )
        : const InputDecoration(
            border: OutlineInputBorder(),
          );

    final field = TextField(
      controller: channelTextController,
      focusNode: channelTextFocusNode,
      textAlign: TextAlign.center,
      textAlignVertical: TextAlignVertical.center,
      style: TextStyle(fontSize: bigControls ? 22 : 16),
      decoration: inputDecoration,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onSubmitted: (value) {
        int? channel = int.tryParse(value);
        if (channel != null) {
          final cfgCmd = SXiSelectChannelCommand(
            ChanSelectionType.tuneUsingChannelNumber,
            channel,
            0xFF,
            ChannelAttributes.all(),
            AudioRoutingType.routeToAudio,
          );
          deviceLayer.sendControlCommand(cfgCmd);
        }
      },
      onTap: () {
        channelTextController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: channelTextController.text.length,
        );
      },
      onTapOutside: (_) {
        FocusManager.instance.primaryFocus?.unfocus();
      },
    );

    return SizedBox(
      width: textFieldWidth,
      height: controlHeight,
      child: field,
    );
  }

  // Build the channel controls
  Widget _buildChannelControls() {
    final bool small = appState.smallScreenMode;
    // Keep original sizing unless we're in small-screen landscape
    final double spacing = 20.0;
    const double textFieldWidth = 100.0;

    final bool smallLandscape = small && isLandscape(context);
    if (smallLandscape) {
      // In small-screen landscape, browse and input are shown in the header row
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ElevatedButton.icon(
          onPressed: () {
            final cfgCmd = SXiSelectChannelCommand(
              ChanSelectionType.tuneToNextLowerChannelNumberInCategory,
              appState.nowPlaying.channelNumber,
              0xFF,
              ChannelAttributes.all(),
              AudioRoutingType.routeToAudio,
            );
            deviceLayer.sendControlCommand(cfgCmd);
          },
          label: const Text('CH'),
          icon: const Icon(Icons.keyboard_arrow_left),
        ),
        SizedBox(width: spacing),
        SizedBox(
          width: textFieldWidth,
          child: _buildChannelNumberInput(bigControls: false),
        ),
        SizedBox(width: spacing),
        ElevatedButton.icon(
          onPressed: () {
            final cfgCmd = SXiSelectChannelCommand(
              ChanSelectionType.tuneToNextHigherChannelNumberInCategory,
              appState.nowPlaying.channelNumber,
              0xFF,
              ChannelAttributes.all(),
              AudioRoutingType.routeToAudio,
            );
            deviceLayer.sendControlCommand(cfgCmd);
          },
          label: const Text('CH'),
          icon: const Icon(Icons.keyboard_arrow_right),
          iconAlignment: IconAlignment.end,
        ),
      ],
    );
  }

  // Build the transport slider
  Widget _buildTransportSlider() {
    if (appState.smallScreenMode) {
      return const SizedBox.shrink();
    }
    if (appState.playbackState == AppPlaybackState.live ||
        appState.isTuneMixActive) {
      return const SizedBox.shrink();
    }

    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            '-${formatDuration(appState.playbackTimeRemaining)}',
            style: TextStyle(fontSize: 14),
          ),
        ),
        Expanded(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 6.0,
                  trackShape: TrackMarkerSliderTrackShape(
                    playbackInfo:
                        appState.channelPlaybackMetadata.values.toList(),
                    totalBufferTime: appState.playbackTimeBefore +
                        appState.playbackTimeRemaining,
                  ),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 10,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                ),
                child: Listener(
                  onPointerMove: (event) {
                    if (!transportDragging || _sliderDragCanceled) return;
                    // Keep the info box on top of the slider view
                    final renderBox = sliderKey.currentContext
                        ?.findRenderObject() as RenderBox?;
                    if (renderBox == null) return;
                    final localPosition =
                        renderBox.globalToLocal(event.position);
                    final size = renderBox.size;
                    final Rect expandedBounds = Offset.zero & size;
                    final Rect cancelBounds = expandedBounds.inflate(
                      sliderDragCancelMarginPx,
                    );
                    if (!cancelBounds.contains(localPosition)) {
                      setState(() {
                        _sliderDragCanceled = true;
                        transportDragging = false;
                        currentSnapInfo = null;
                        if (_transportValueBeforeDrag != null) {
                          transportValue = _transportValueBeforeDrag!;
                        }
                      });
                    }
                  },
                  child: Slider(
                    key: sliderKey,
                    value: transportValue,
                    onChanged: appState.isScanActive
                        ? null
                        : (value) {
                            if (_sliderDragCanceled) return;
                            setState(() {
                              final totalBufferTime =
                                  appState.playbackTimeBefore +
                                      appState.playbackTimeRemaining;

                              if (appState.sliderSnapping) {
                                final snapInfo =
                                    TrackSnappingHelper.findSnapCandidate(
                                  value,
                                  appState.channelPlaybackMetadata.values
                                      .toList(),
                                  totalBufferTime,
                                );

                                if (snapInfo != null) {
                                  transportValue = snapInfo.snapPosition;
                                  currentSnapInfo = snapInfo;
                                } else {
                                  transportValue = value;
                                  currentSnapInfo =
                                      TrackSnappingHelper.findTrackAtPosition(
                                    value,
                                    appState.channelPlaybackMetadata.values
                                        .toList(),
                                    totalBufferTime,
                                  );
                                }
                              } else {
                                transportValue = value;
                                currentSnapInfo =
                                    TrackSnappingHelper.findTrackAtPosition(
                                  value,
                                  appState.channelPlaybackMetadata.values
                                      .toList(),
                                  totalBufferTime,
                                );
                              }
                            });
                          },
                    onChangeStart: appState.isScanActive
                        ? null
                        : (value) {
                            setState(() {
                              transportDragging = true;
                              _sliderDragCanceled = false;
                              _transportValueBeforeDrag = transportValue;
                            });
                          },
                    onChangeEnd: appState.isScanActive
                        ? null
                        : (value) {
                            if (_sliderDragCanceled) {
                              setState(() {
                                transportDragging = false;
                                currentSnapInfo = null;
                                if (_transportValueBeforeDrag != null) {
                                  transportValue = _transportValueBeforeDrag!;
                                }
                              });
                              _sliderDragCanceled = false;
                              return;
                            }
                            setState(() {
                              transportDragging = false;
                              currentSnapInfo = null;
                            });
                            var nextValue = transportValue *
                                (appState.playbackTimeBefore +
                                    appState.playbackTimeRemaining);
                            audioServiceHandler?.seek(
                              Duration(seconds: nextValue.round()),
                            );
                          },
                  ),
                ),
              ),
              // Show popup when snapped and dragging
              if (currentSnapInfo != null && transportDragging)
                TrackInfoPopup(
                  snapInfo: currentSnapInfo!,
                  position: _getPopupPosition(),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            formatDuration(
              appState.playbackTimeBefore + appState.playbackTimeRemaining,
            ),
            style: TextStyle(fontSize: 14),
          ),
        ),
      ],
    );
  }

  // Build the aired text info
  Widget _buildAiredInfo() {
    final int secondsAgo = appState.playbackTimeRemaining;
    final int minutesAgo = (secondsAgo / 60).floor();
    final String label = appState.isTuneMixActive
        ? 'Aired Earlier'
        : 'Aired $minutesAgo minute${minutesAgo == 1 ? '' : 's'} ago';
    return Center(
      child: Text(
        label,
        style: const TextStyle(fontSize: 14),
        textAlign: TextAlign.center,
      ),
    );
  }

  // Build the transport area
  Widget _buildTransportArea() {
    final bool showAired = appState.isScanActive || appState.isTuneMixActive;
    if (appState.smallScreenMode) {
      if (showAired) {
        return SizedBox(height: 28, child: _buildAiredInfo());
      }
      return const SizedBox.shrink();
    }

    const double areaHeight = 56;
    final bool showSlider =
        appState.playbackState != AppPlaybackState.live && !showAired;
    return SizedBox(
      height: areaHeight,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: showAired
            ? _buildAiredInfo()
            : (showSlider ? _buildTransportSlider() : const SizedBox.shrink()),
      ),
    );
  }

  // Get the position of the info popup
  Offset _getPopupPosition() {
    if (sliderKey.currentContext == null || currentSnapInfo == null) {
      return const Offset(100, 0);
    }

    final RenderBox? renderBox =
        sliderKey.currentContext!.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      return const Offset(100, 0);
    }

    final size = renderBox.size;

    // Calculate the horizontal position based on the current slider position
    final snapX = currentSnapInfo!.snapPosition * size.width;

    // Return local coordinates relative to the Stack
    return Offset(snapX, 0);
  }

  // Save the EQ
  void saveEq() {
    var savedEq = appState.eqSliderValues.map((val) => val.round()).toList();
    appState.storageData.save(SaveDataType.eq, Int8List.fromList(savedEq));
    logger.d('Saved EQ: $savedEq');
  }

  // Calculate the EQ values in the range
  List<int> calcEq() {
    return appState.eqSliderValues
        .sublist(1, appState.eqSliderValues.length - 1)
        .map(
          (val) => (val +
                  appState.eqSliderValues[appState.eqSliderValues.length - 1])
              .clamp(-maxEq, maxEq)
              .round(),
        )
        .toList();
  }

  // Send the EQ to the device
  void sendEq() {
    saveEq();

    var eqList = calcEq();
    logger.t('Send EQ to device: $eqList');
    var eqCmd = SXiAudioEqualizerCommand(eqList);
    deviceLayer.sendControlCommand(eqCmd);
  }

  // Send the volume to the device
  void sendVol() {
    saveEq();

    int volume = appState.eqSliderValues[0].round();
    logger.t('Send Vol to device: $volume');
    var volCmd = SXiAudioVolumeCommand(volume);
    deviceLayer.sendControlCommand(volCmd);
  }

  // Save the presets locally
  void savePresets() {
    var savedPresets = appState.presets;
    appState.storageData.save(SaveDataType.presets, savedPresets);
    logger.d('Saved Presets: $savedPresets');
  }

  // Send the presets to the device
  void sendPresets() {
    savePresets();

    var savedPresets = appState.presets.map((preset) => preset.sid).toList();
    logger.d('Send Presets to device: $savedPresets');
    List<int> presets = List<int>.filled(20, 1);
    for (int i = 0; i < savedPresets.length; i++) {
      presets[i] = savedPresets[i];
    }
    var presetCmd = SXiListChannelAttributesCommand(
      ChanAttribListChangeType.smartFavorite,
      presets,
    );
    deviceLayer.sendControlCommand(presetCmd);

    var tunemixCmd = SXiListChannelAttributesCommand(
      ChanAttribListChangeType.tuneMix1,
      presets,
    );
    deviceLayer.sendControlCommand(tunemixCmd);
  }
}
