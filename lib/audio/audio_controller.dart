import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_recorder/flutter_recorder.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:orbit/logging.dart';

class AudioController {
  bool _useIsolate = false;
  late SendPort _audioSendPort;
  ReceivePort? _receivePort;
  ReceivePort? _isolateExitPort;
  // Tracks whether we've initialized and/or started components to allow safe teardown
  bool _audioStreamInitialized = false;
  bool _recordStreamStarted = false;
  bool _isolateInitialized = false;
  bool _isStarted = false;
  String? _androidAudioOutputRoute;
  bool _detectAudioInterruptions = true;

  final AudioStream _audioStream = getAudioStream();
  final PCMFormat format = PCMFormat.f32le;
  int sampleRate = 48000;
  final RecorderChannels channels = RecorderChannels.stereo;
  final recorder = Recorder.instance;
  final record = AudioRecorder();
  bool _isPlayingTone = false;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  bool _wasPausedByInterruption = false;

  final _androidAudioManager =
      !kIsWeb && !kIsWasm && defaultTargetPlatform == TargetPlatform.android
          ? AndroidAudioManager()
          : null;

  bool get usesRecordPlugin =>
      kIsWasm || kIsWeb || defaultTargetPlatform == TargetPlatform.android;

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
    if (!usesRecordPlugin) {
      // We should check permission with flutter_recorder...
      return true;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      PermissionStatus status = await Permission.microphone.status;
      if (status.isGranted) return true;
      status = await Permission.microphone.request();
      return status.isGranted;
    }

    try {
      logger.d('Checking microphone permission on web');
      final hasPermission = await record.hasPermission();
      logger.d('Input permission granted: $hasPermission');
      if (hasPermission) return true;
      logger.w('Input permission not granted');
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<List<dynamic>> getAvailableInputDevices() async {
    if (usesRecordPlugin) {
      return await record.listInputDevices();
    } else {
      return recorder.listCaptureDevices();
    }
  }

  String getDeviceName(dynamic device) {
    if (usesRecordPlugin && device is InputDevice) {
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
    if (preferredSampleRate != null && preferredSampleRate > 0) {
      sampleRate = preferredSampleRate;
    } else {
      sampleRate = 48000;
    }
    // Initialize the AudioSession (runs on the main isolate)
    var session = await AudioSession.instance;
    if (await session.setActive(true,
        androidWillPauseWhenDucked: _detectAudioInterruptions)) {
      logger.i('Audio session active');
    } else {
      logger.e('Audio session setup failed');
      return;
    }

    // Centralize handling of interruptions
    try {
      await _interruptionSub?.cancel();
    } catch (_) {}
    if (_detectAudioInterruptions) {
      _interruptionSub = session.interruptionEventStream.listen((event) async {
        logger.d('Audio interruption: begin=${event.begin} type=${event.type}');
        if (event.begin) {
          // Pause capture if currently recording
          try {
            if (_recordStreamStarted) {
              final isRec = await record.isRecording();
              final isPaused = await record.isPaused();
              if (isRec && !isPaused) {
                _wasPausedByInterruption = true;
                await record.pause();
              }
            }
          } catch (_) {}
        } else {
          // Resume only if we paused due to the interruption
          if (_wasPausedByInterruption) {
            // Re-apply preferred route first to avoid stale routing after Assistant
            await _applyPreferredAndroidRoute();
            _wasPausedByInterruption = false;
            try {
              await record.resume();
            } catch (_) {}
          }
        }
      });
    } else {
      _interruptionSub = null;
    }

    if (usesRecordPlugin) {
      _useIsolate = false;
      // Remember route for re-application after interruption
      _androidAudioOutputRoute = androidAudioOutputRoute;
      if (defaultTargetPlatform == TargetPlatform.android) {
        PermissionStatus status = await Permission.microphone.request();
        if (!status.isGranted) {
          await [Permission.microphone].request();
        }
      }

      _audioStream.init(
        waitingBufferMilliSec: 0,
        bufferMilliSec: 500,
        sampleRate: sampleRate,
        channels: 2,
      );
      _audioStreamInitialized = true;

      // Apply preferred Android audio route after audio is active
      await _applyPreferredAndroidRoute();

      _audioStream.resume();
      _runAudioInputNonIsolate(
          selectedDevice: selectedDevice, effectiveSampleRate: sampleRate);
      _isStarted = true;
    } else {
      // For non‑Android and non-Web, spawn an isolate
      _useIsolate = true;
      _receivePort = ReceivePort();
      _isolateExitPort = ReceivePort();
      await Isolate.spawn(
        _audioIsolateEntry,
        _receivePort!.sendPort,
        debugName: 'AudioIsolate',
        onExit: _isolateExitPort!.sendPort,
      );
      _audioSendPort = await _receivePort!.first;
      _isolateInitialized = true;
      _audioSendPort.send({
        'cmd': 'init',
        'selectedDevice': selectedDevice,
        'preferredSampleRate': sampleRate,
      });
      _isStarted = true;
    }
  }

  void playTestTone(int frequency, int durationSeconds) async {
    logger.t(
        'playTestTone: $frequency Hz, $durationSeconds s | usingIsolate=$_useIsolate');
    if (_useIsolate) {
      logger.t('Playing test tone in isolate');
      _audioSendPort.send({
        'cmd': 'playTestTone',
        'frequency': frequency,
        'durationSeconds': durationSeconds
      });
      return;
    }

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
  void _runAudioInputNonIsolate(
      {dynamic selectedDevice, int? effectiveSampleRate}) async {
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
      ),
      // Plugin interruption behavior depends on setting (pause only, resume by us)
      audioInterruption: _detectAudioInterruptions
          ? AudioInterruptionMode.pause
          : AudioInterruptionMode.none,
      device: device,
    ));
    _recordStreamStarted = true;

    recordStream.listen((stream) {
      if (_isPlayingTone) return;
      _audioStream.push(_convertUint8ListToFloat32List(stream));
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
    logger.t('stopAudioThread: started=$_isStarted, useIsolate=$_useIsolate');
    // Stop interruption subscription
    try {
      await _interruptionSub?.cancel();
    } catch (_) {}
    _interruptionSub = null;
    if (_useIsolate) {
      // Only attempt to send stop if isolate was fully initialized
      if (_isolateInitialized) {
        try {
          _audioSendPort.send({'cmd': 'stop'});
        } catch (_) {}
      }
      final exitPort = _isolateExitPort;
      if (exitPort != null) {
        try {
          // Wait briefly for the isolate to exit after cleanup
          await exitPort.first.timeout(const Duration(seconds: 2));
        } catch (_) {}
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      try {
        _receivePort?.close();
      } catch (_) {}
      _receivePort = null;
      try {
        _isolateExitPort?.close();
      } catch (_) {}
      _isolateExitPort = null;
      _isolateInitialized = false;
    } else {
      // Stop input stream if it was started
      try {
        if (_recordStreamStarted) {
          await record.stop();
        }
      } catch (_) {}
      _recordStreamStarted = false;
      // Dispose may be safe to call repeatedly in the plugin; ignore errors
      try {
        await record.dispose();
      } catch (_) {}
      // Only uninit output if it was previously initialized
      try {
        if (_audioStreamInitialized) {
          _audioStream.uninit();
        }
      } catch (_) {}
      _audioStreamInitialized = false;
    }
    _isStarted = false;
  }

  void dispose() {
    unawaited(stopAudioThread());
  }
}

// Entry point for the processing isolate (for non-Android and non-Web)
void _audioIsolateEntry(SendPort mainSendPort) async {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);

  final AudioStream audioStream = getAudioStream();
  const PCMFormat format = PCMFormat.f32le;
  int sampleRate = 48000;
  const RecorderChannels channels = RecorderChannels.stereo;
  final recorder = Recorder.instance;
  bool running = true;
  bool isPlayingTone = false;

  // Initialize the audio stream in the isolate
  Future<void> initAudio({int? preferredSampleRate}) async {
    logger.t('Initializing audio in isolate');
    if (preferredSampleRate != null && preferredSampleRate > 0) {
      sampleRate = preferredSampleRate;
    }
    audioStream.init(
      waitingBufferMilliSec: 0,
      bufferMilliSec: 500,
      sampleRate: sampleRate,
      channels: 2,
    );

    // Ensure output is active
    audioStream.resume();
  }

  // Runs audio capture using record
  Future<void> runAudioInput(
      {dynamic selectedDevice, int? preferredSampleRate}) async {
    logger.t('Running audio input on $defaultTargetPlatform in isolate');
    var allDevices = recorder.listCaptureDevices();
    logger.t(allDevices.map((dev) => (dev as dynamic).name).toString());

    dynamic device;
    if (selectedDevice != null) {
      for (var dev in allDevices) {
        if ((dev as dynamic).name == (selectedDevice as dynamic).name) {
          device = dev;
          break;
        }
      }
      if (device != null) {
        logger.t('Using selected device: ${(device as dynamic).name}');
      } else {
        logger.t('Selected device not found, using first available');
        device = allDevices.first;
      }
    } else {
      device = allDevices.first;
      logger.t('Auto-selected first device: ${(device as dynamic).name}');
    }

    if (preferredSampleRate != null && preferredSampleRate > 0) {
      sampleRate = preferredSampleRate;
    }

    await recorder.init(
      format: format,
      sampleRate: sampleRate,
      channels: channels,
      deviceID: (device as dynamic).id,
    );

    recorder.start();
    recorder.uint8ListStream.listen((data) {
      if (!running || isPlayingTone) return;
      audioStream.push(data.toF32List(from: format));
    });

    recorder.startStreamingData();
  }

  await for (var message in port) {
    if (message is Map) {
      logger.t('message: $message');
      switch (message['cmd']) {
        case 'init':
          await initAudio(
              preferredSampleRate: message['preferredSampleRate'] as int?);
          runAudioInput(
            selectedDevice: message['selectedDevice'],
            preferredSampleRate: message['preferredSampleRate'] as int?,
          );
          break;
        case 'playTestTone':
          try {
            isPlayingTone = true;
            final int frequency = (message['frequency'] as int?) ?? 440;
            final int durationSeconds =
                (message['durationSeconds'] as int?) ?? 1;
            final int framesPerSecond = sampleRate;
            const int channelsCount = 2;
            const double amplitude = 0.2;
            final double twoPi = 2 * math.pi;
            final double phaseIncrement = twoPi * frequency / framesPerSecond;
            double phase = 0;

            // Push smaller chunks (~50ms) to avoid overflowing small buffers
            final int chunkFrames = (framesPerSecond / 20).floor();
            final int totalChunks = durationSeconds * 20;
            for (int chunk = 0; chunk < totalChunks; chunk++) {
              final Float32List buffer =
                  Float32List(chunkFrames * channelsCount);
              int writeIndex = 0;
              for (int n = 0; n < chunkFrames; n++) {
                final sample = (math.sin(phase) * amplitude).toDouble();
                phase += phaseIncrement;
                if (phase >= twoPi) phase -= twoPi;
                buffer[writeIndex++] = sample;
                buffer[writeIndex++] = sample;
              }
              audioStream.push(buffer);
              if (chunk < totalChunks - 1) {
                await Future.delayed(const Duration(milliseconds: 50));
              }
            }
          } catch (_) {
            // Ignore errors
          }
          isPlayingTone = false;
          break;
        case 'stop':
          try {
            recorder.stop();
          } catch (_) {}
          try {
            recorder.deinit();
          } catch (_) {}
          try {
            audioStream.uninit();
          } catch (_) {}
          running = false;
          try {
            port.close();
          } catch (_) {}
          Isolate.exit();
        default:
          break;
      }
    }
  }
}
