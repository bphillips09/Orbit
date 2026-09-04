import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:orbit/logging.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_payload.dart';

class HostAudioPlaybackDebug {
  static const int bitrateKbps = 32;
  static const Duration testDuration = Duration(seconds: 3);

  final void Function(SXiPayload payload) sendControl;
  final Uint8List _audioData;
  int _packetsSent = 0;
  bool _running = false;
  bool _analogToneOn = false;
  Timer? _timeout;
  Timer? _toneTimer;

  HostAudioPlaybackDebug(this.sendControl)
      : _audioData = generateToneBytes(
          duration: testDuration,
          bitrateKbps: bitrateKbps,
        );

  bool get isRunning => _running;

  static Uint8List generateToneBytes({
    required Duration duration,
    required int bitrateKbps,
    double frequencyHz = 440,
  }) {
    final int byteRate = (bitrateKbps * 1000) ~/ 8;
    final int totalBytes = byteRate * duration.inMilliseconds ~/ 1000;
    final Uint8List bytes = Uint8List(totalBytes);
    for (int i = 0; i < totalBytes; i++) {
      final double sample = sin(2 * pi * frequencyHz * i / byteRate);
      bytes[i] = ((sample * 0.45 + 0.5) * 255).round().clamp(0, 255);
    }
    return bytes;
  }

  void start() {
    if (_running) {
      logger.w('HAP debug: already running');
      return;
    }

    _running = true;
    _packetsSent = 0;
    _analogToneOn = false;
    logger.i('HAP debug: starting ${testDuration.inSeconds}s host audio '
        '(${_audioData.length} bytes, encoder 6, ${bitrateKbps}kbps)');

    sendControl(SXiSelectChannelCommand(
      ChanSelectionType.playHostAudio,
      0,
      0,
      0,
      AudioRoutingType.noRouting,
    ));

    _timeout = Timer(testDuration, stop);
  }

  SXiPlaybackAudioPacketCommand? packetForRequest(int packetId) {
    if (!_running) return null;

    _ensureAnalogTone();

    if (packetId < 0 || packetId >= _audioData.length) {
      logger.i('HAP debug: request offset=$packetId past end '
          '(${_audioData.length}), ignoring');
      return null;
    }

    final int remaining = _audioData.length - packetId;
    final int chunkLen =
        min(SXiPlaybackAudioPacketCommand.maxPacketBytes, remaining);
    final bool last = packetId + chunkLen >= _audioData.length;
    final List<int> chunk = _audioData.sublist(packetId, packetId + chunkLen);
    _packetsSent += 1;

    logger.i('HAP debug: TX offset: $packetId bytes: $chunkLen last $last '
        'sent: $_packetsSent clip: ${_audioData.length}');

    return SXiPlaybackAudioPacketCommand(
      packetId: packetId,
      bitrateKbps: bitrateKbps,
      lastPacket: last,
      audioData: chunk,
    );
  }

  void _ensureAnalogTone() {
    if (_analogToneOn || !_running) return;
    _analogToneOn = true;
    // Let the ACK go out first so these do not collide
    _toneTimer?.cancel();
    _toneTimer = Timer(const Duration(milliseconds: 80), () {
      if (!_running) return;
      sendControl(SXiAudioMuteCommand(AudioMuteType.unmute));
      sendControl(SXiAudioToneGenerateCommand(
        440,
        AudioLeftRightType.both,
        AudioAlertType.none,
        0,
      ));
      logger.i('HAP debug: analog 440 Hz');
    });
  }

  void stop() {
    _timeout?.cancel();
    _timeout = null;
    _toneTimer?.cancel();
    _toneTimer = null;
    if (!_running) return;
    _running = false;
    logger.i('HAP debug: aborting host-audio playback');
    if (_analogToneOn) {
      sendControl(SXiAudioToneGenerateCommand(
        440,
        AudioLeftRightType.none,
        AudioAlertType.none,
        0,
      ));
      _analogToneOn = false;
    }
    sendControl(SXiSelectChannelCommand(
      ChanSelectionType.abortHostAudioPlayback,
      0,
      0,
      0,
      AudioRoutingType.noRouting,
    ));
  }
}
