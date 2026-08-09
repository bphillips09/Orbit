import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:orbit/logging.dart';

/// Top-level entry used by [FlutterForegroundTask.startService].
@pragma('vm:entry-point')
void startOrbitAudioForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_OrbitAudioForegroundHandler());
}

/// Keeps a microphone foreground service alive while Orbit captures audio
class AndroidAudioForeground {
  AndroidAudioForeground._();

  static const int _serviceId = 401;
  static bool _initialized = false;
  static bool _started = false;

  static bool get _isAndroid =>
      !kIsWeb && !kIsWasm && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> ensureInitialized() async {
    if (!_isAndroid || _initialized) return;

    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'orbit_audio_input',
        channelName: 'Orbit Audio Input',
        channelDescription:
            'Shown while Orbit is capturing audio input on Android.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    _initialized = true;
  }

  static Future<void> start() async {
    if (!_isAndroid) return;
    await ensureInitialized();

    final NotificationPermission permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) {
      _started = true;
      return;
    }

    final ServiceRequestResult result =
        await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const <ForegroundServiceTypes>[
        ForegroundServiceTypes.microphone,
      ],
      notificationTitle: 'Orbit',
      notificationText: 'Processing audio input...',
      callback: startOrbitAudioForegroundCallback,
    );

    if (result is ServiceRequestFailure) {
      logger.w(
          'Android audio foreground service failed to start: ${result.error}');
      _started = false;
      return;
    }

    _started = true;
    logger.t('Android audio foreground service started');
  }

  static Future<void> stop() async {
    if (!_isAndroid) return;

    try {
      if (_started || await FlutterForegroundTask.isRunningService) {
        final ServiceRequestResult result =
            await FlutterForegroundTask.stopService();
        if (result is ServiceRequestFailure) {
          logger.w(
              'Android audio foreground service failed to stop: ${result.error}');
        } else {
          logger.t('Android audio foreground service stopped');
        }
      }
    } catch (e) {
      logger.w('Android audio foreground service stop error: $e');
    } finally {
      _started = false;
    }
  }
}

class _OrbitAudioForegroundHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
