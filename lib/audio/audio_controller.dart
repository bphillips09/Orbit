import 'dart:async';
import 'dart:math' as math;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:orbit/logging.dart';

class AudioController {
  // Tracks whether we've initialized and/or started components to allow safe teardown
  bool _audioStreamInitialized = false;
  bool _recordStreamStarted = false;
  bool _isStarted = false;
  String? _androidAudioOutputRoute;
  bool _detectAudioInterruptions = true;

  final AudioStream _audioStream = getAudioStream();
  int sampleRate = 48000;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _recordStreamSub;
  bool _isPlayingTone = false;
  bool _wasPausedByInterruption = false;
  bool _isDucked = false;
  static const double _duckGain = 0.2;
  bool _isPlayingNotificationTone = false;
  Float32List? _notificationToneMixBuffer;
  int _notificationToneMixPos = 0;

  AudioController() {
    logger.t('AudioController initialized');
    if (!kIsWeb && !kIsWasm) return;
    _prewarmWebOutput();
  }

  void _prewarmWebOutput() {
    if (_audioStreamInitialized) return;

    try {
      _audioStream.init(
        waitingBufferMilliSec: 0,
        bufferMilliSec: 500,
        sampleRate: sampleRate,
        channels: 2,
      );
      _audioStreamInitialized = true;
    } catch (_) {}
  }

  Future<void> ensureWebAudioResumedFromGesture() async {
    if (!kIsWeb && !kIsWasm) return;
    if (!_audioStreamInitialized) {
      _prewarmWebOutput();
    }
    try {
      _audioStream.resume();
    } catch (_) {}
  }

  void _armNotificationToneMix(Float32List toneBuffer) {
    _notificationToneMixBuffer = toneBuffer;
    _notificationToneMixPos = 0;
    _isPlayingNotificationTone = true;
  }

  void _mixNotificationToneInPlace(Float32List io) {
    final tone = _notificationToneMixBuffer;
    if (tone == null) return;

    final int remaining = tone.length - _notificationToneMixPos;
    if (remaining <= 0) {
      _notificationToneMixBuffer = null;
      _notificationToneMixPos = 0;
      _isPlayingNotificationTone = false;
      return;
    }

    final int mixLen = math.min(io.length, remaining);
    int toneIndex = _notificationToneMixPos;
    for (int i = 0; i < mixLen; i++) {
      final double s = io[i] + tone[toneIndex++];
      // Saturate to avoid clipping
      io[i] = s > 1.0 ? 1.0 : (s < -1.0 ? -1.0 : s);
    }

    _notificationToneMixPos = toneIndex;
    if (_notificationToneMixPos >= tone.length) {
      _notificationToneMixBuffer = null;
      _notificationToneMixPos = 0;
      _isPlayingNotificationTone = false;
    }
  }

  AudioRecorder _ensureRecorder() {
    return _recorder ??= AudioRecorder();
  }

  final _androidAudioManager =
      !kIsWeb && !kIsWasm && defaultTargetPlatform == TargetPlatform.android
          ? AndroidAudioManager()
          : null;

  Future<bool> switchToSpeaker() async {
    if (_androidAudioManager != null) {
      await _androidAudioManager.setMode(
        AndroidAudioHardwareMode.inCommunication,
      );
      await _androidAudioManager.stopBluetoothSco();
      await _androidAudioManager.setBluetoothScoOn(false);
      await _androidAudioManager.setSpeakerphoneOn(true);
    }
    return true;
  }

  Future<bool> switchToReceiver() async {
    if (_androidAudioManager != null) {
      _androidAudioManager.setMode(AndroidAudioHardwareMode.inCommunication);
      _androidAudioManager.stopBluetoothSco();
      _androidAudioManager.setBluetoothScoOn(false);
      _androidAudioManager.setSpeakerphoneOn(false);
      return true;
    }
    return false;
  }

  Future<bool> switchToHeadphones() async {
    if (_androidAudioManager != null) {
      _androidAudioManager.setMode(AndroidAudioHardwareMode.normal);
      _androidAudioManager.stopBluetoothSco();
      _androidAudioManager.setBluetoothScoOn(false);
      _androidAudioManager.setSpeakerphoneOn(false);
      return true;
    }
    return true;
  }

  Future<bool> switchToBluetooth() async {
    if (_androidAudioManager != null) {
      await _androidAudioManager.setMode(
        AndroidAudioHardwareMode.inCommunication,
      );
      await _androidAudioManager.startBluetoothSco();
      await _androidAudioManager.setBluetoothScoOn(true);
      return true;
    }
    return false;
  }

  Future<void> _applyPreferredAndroidRoute() async {
    if (!kIsWeb &&
        !kIsWasm &&
        defaultTargetPlatform == TargetPlatform.android) {
      final route = _androidAudioOutputRoute;
      logger.d('Applying Android audio route preference: $route');
      switch (route) {
        case 'Receiver':
          await switchToReceiver();
          break;
        case 'Headphones':
          await switchToHeadphones();
          break;
        case 'Bluetooth':
          await switchToBluetooth();
          break;
        case 'Speaker':
        default:
          await switchToSpeaker();
          break;
      }
    }
  }

  // Ensure microphone permission is granted where needed (Web/Wasm/Android)
  Future<bool> ensureMicrophonePermission() async {
    if (!kIsWeb &&
        !kIsWasm &&
        defaultTargetPlatform == TargetPlatform.android) {
      PermissionStatus status = await Permission.microphone.status;
      if (status.isGranted) return true;
      status = await Permission.microphone.request();
      return status.isGranted;
    }

    try {
      logger.d('Checking microphone permission');
      final hasPermission = await _ensureRecorder().hasPermission();
      logger.d('Input permission granted: $hasPermission');
      if (hasPermission) return true;
      logger.w('Input permission not granted');
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<List<dynamic>> getAvailableInputDevices() async {
    return await _ensureRecorder().listInputDevices();
  }

  String getDeviceName(dynamic device) {
    if (device is InputDevice) {
      return device.label;
    } else {
      try {
        return (device as dynamic).name;
      } catch (e) {
        return 'Unknown Device';
      }
    }
  }

  Future<void> startAudioThread(
      {dynamic selectedDevice,
      String? androidAudioOutputRoute,
      bool detectAudioInterruptions = true,
      int? preferredSampleRate}) async {
    logger.t('startAudioThread: $selectedDevice at $preferredSampleRate');
    _detectAudioInterruptions = detectAudioInterruptions;
    if (_isStarted) {
      try {
        await stopAudioThread();
      } catch (_) {}
    }
    if (preferredSampleRate != null && preferredSampleRate > 0) {
      sampleRate = preferredSampleRate;
    } else {
      sampleRate = 48000;
    }

    // Initialize the AudioSession.
    final session = await AudioSession.instance;
    try {
      await session.configure(
        AudioSessionConfiguration(
          androidAudioAttributes: const AndroidAudioAttributes(
            contentType: AndroidAudioContentType.music,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: false,
        ),
      );
    } catch (e, st) {
      logger.w('AudioSession configure failed: $e\n$st');
    }

    if (await session.setActive(
      true,
      androidWillPauseWhenDucked: false,
    )) {
      logger.i('Audio session active');
    } else {
      logger.e('Audio session setup failed');
      return;
    }

    // Remember route for re-application after interruption
    _androidAudioOutputRoute = androidAudioOutputRoute;
    if (!kIsWeb &&
        !kIsWasm &&
        defaultTargetPlatform == TargetPlatform.android) {
      PermissionStatus status = await Permission.microphone.request();
      if (!status.isGranted) {
        await [Permission.microphone].request();
      }
    }

    if ((kIsWeb || kIsWasm) && _audioStreamInitialized) {
      // Already initialized
    } else {
      _audioStream.init(
        waitingBufferMilliSec: 0,
        bufferMilliSec: 500,
        sampleRate: sampleRate,
        channels: 2,
      );
      _audioStreamInitialized = true;
    }

    // Apply preferred Android audio route after audio is active
    await _applyPreferredAndroidRoute();

    _audioStream.resume();
    try {
      await _runAudioInputNonIsolate(
        selectedDevice: selectedDevice,
        effectiveSampleRate: sampleRate,
      );
      _isStarted = true;
    } catch (e, st) {
      logger.e('Failed to start audio input: $e\n$st');
      try {
        await stopAudioThread();
      } catch (_) {}
    }
  }

  void playTestTone(int frequency, int durationSeconds) async {
    logger.t(
        'playTestTone: $frequency Hz, $durationSeconds s | sampleRate=$sampleRate');

    // Generate and push small chunks (~50ms) to respect output buffer capacity
    final int framesPerSecond = sampleRate;
    const int channelsCount = 2;
    const double amplitude = 0.2; // keep headroom
    final double twoPi = 2 * math.pi;
    final double phaseIncrement = twoPi * frequency / framesPerSecond;
    double phase = 0;
    final int chunkFrames = (framesPerSecond / 20).floor(); // 50ms
    final int totalChunks = durationSeconds * 20;

    _isPlayingTone = true;
    for (int chunk = 0; chunk < totalChunks; chunk++) {
      final Float32List buffer = Float32List(chunkFrames * channelsCount);
      int writeIndex = 0;
      for (int n = 0; n < chunkFrames; n++) {
        final floatSample = (math.sin(phase) * amplitude).toDouble();
        phase += phaseIncrement;
        if (phase >= twoPi) phase -= twoPi;
        buffer[writeIndex++] = floatSample;
        buffer[writeIndex++] = floatSample;
      }
      _audioStream.push(buffer);
      if (chunk < totalChunks - 1) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    _isPlayingTone = false;
  }

  // Runs audio capture on Android using the Record plugin on main isolate
  Future<void> _runAudioInputNonIsolate(
      {dynamic selectedDevice, int? effectiveSampleRate}) async {
    final record = _ensureRecorder();
    await record.hasPermission();
    logger.t('Running audio input on main isolate');
    List<InputDevice> allDevices = [];
    try {
      logger.t('Listing input devices');
      allDevices = await record.listInputDevices();
      logger.t('Input devices: ${allDevices.map((dev) => dev.label)}');
    } catch (e) {
      logger.w('Error listing input devices: $e');
    }

    InputDevice? device;
    if (selectedDevice != null && selectedDevice is InputDevice) {
      device = selectedDevice;
      logger.t('Using selected device: ${device.label}');
    } else if (allDevices.isNotEmpty) {
      device = allDevices.first;
      logger.t('Auto-selected device: ${device.label}');
    } else {
      device = null;
      logger.t('No input devices returned; falling back to default microphone');
    }

    final int sr = effectiveSampleRate ?? sampleRate;
    final recordStream = await record.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sr,
      numChannels: 2,
      androidConfig: const AndroidRecordConfig(
        manageBluetooth: false,
        audioSource: AndroidAudioSource.unprocessed,
        service: AndroidService(
          title: 'Orbit',
          content: 'Processing audio input...',
        ),
      ),
      audioInterruption: AudioInterruptionMode.none,
      device: device,
    ));

    _recordStreamStarted = true;

    try {
      await _recordStreamSub?.cancel();
    } catch (_) {}
    _recordStreamSub = recordStream.listen((stream) {
      if (_isPlayingTone) return;
      _audioStream.push(_convertUint8ListToFloat32List(stream));
    }, onError: (Object e, StackTrace st) {
      logger.e('Audio record stream error: $e\n$st');
    });
  }

  // Utility conversion
  Float32List _convertUint8ListToFloat32List(Uint8List data) {
    int len = data.lengthInBytes ~/ 2;
    Float32List float32List = Float32List(len);
    ByteData byteData = ByteData.sublistView(data);
    for (int i = 0; i < len; i++) {
      int val = byteData.getInt16(i * 2, Endian.little);
      float32List[i] = val / 32768.0;
    }
    return float32List;
  }

  Future<void> stopAudioThread() async {
    logger.t('stopAudioThread: started=$_isStarted');
    try {
      await _recordStreamSub?.cancel();
    } catch (_) {}
    _recordStreamSub = null;

    // Stop input stream if it was started
    try {
      if (_recordStreamStarted) {
        await _recorder?.stop();
      }
    } catch (_) {}
    _recordStreamStarted = false;

    try {
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;

    // Deactivate audio session when possible
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}

    // Only uninit output if it was previously initialized
    if (!(kIsWeb || kIsWasm)) {
      try {
        if (_audioStreamInitialized) {
          _audioStream.uninit();
        }
      } catch (_) {}
      _audioStreamInitialized = false;
    }

    _isStarted = false;
  }

  // Handle an interruption event from the app-level AudioSession listener
  Future<void> handleInterruptionEvent(AudioInterruptionEvent event) async {
    if (!_isStarted) return;
    if (!_detectAudioInterruptions) return;

    logger.d(
        'AudioController interruption: begin=${event.begin} type=${event.type}');

    final bool isDuck = event.type == AudioInterruptionType.duck;

    if (event.begin && isDuck) {
      _isDucked = true;
      return;
    }

    if (!event.begin && isDuck) {
      _isDucked = false;
      return;
    }

    if (event.begin) {
      // Make sure we're not left ducked
      _isDucked = false;
      // Pause capture if currently streaming
      try {
        if (_recordStreamStarted) {
          final rec = _recorder;
          if (rec == null) return;
          final isRec = await rec.isRecording();
          final isPaused = await rec.isPaused();
          if (isRec && !isPaused) {
            _wasPausedByInterruption = true;
            await rec.pause();
          }
        }
      } catch (_) {}
      return;
    }
  }

  // Bring audio back after transient focus loss
  Future<void> recoverAfterInterruption({String reason = ''}) async {
    if (!_isStarted) return;

    // Clear ducking on recovery
    _isDucked = false;

    // Re-apply preferred route first
    try {
      await _applyPreferredAndroidRoute();
    } catch (_) {}

    // Re-activate focus
    try {
      final session = await AudioSession.instance;
      await session.setActive(
        true,
        androidWillPauseWhenDucked: false,
      );
    } catch (_) {}

    // Ensure output is resumed
    try {
      if (_audioStreamInitialized) {
        _audioStream.resume();
      }
    } catch (_) {}

    // Resume capture if we paused it due to the interruption
    if (_wasPausedByInterruption) {
      _wasPausedByInterruption = false;
      try {
        final rec = _recorder;
        if (rec != null) {
          await rec.resume();
        }
      } catch (_) {}
    }

    if (reason.isNotEmpty) {
      logger.i('AudioController recoverAfterInterruption: $reason');
    }
  }

  void dispose() {
    unawaited(stopAudioThread());
  }
}
