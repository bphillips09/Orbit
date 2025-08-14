// A tiny helper to make the browser know the app is playing by outputting
// an extremely quiet silent audio element when the app is playing
import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class NowPlayingIndicator {
  static web.HTMLAudioElement? _indicatorAudio;
  static String? _audioSrc;
  static bool _isPlaying = false;

  static void update({required bool isPlaying}) {
    // Debounce redundant calls
    if (isPlaying == _isPlaying) return;
    _isPlaying = isPlaying;

    try {
      _ensureElement();
      if (isPlaying) {
        // Unmute to trigger the tab's playing indicator, but keep volume minimal
        _indicatorAudio!.muted = false;
        _indicatorAudio!.volume =
            0.0001; // effectively silent but audible to the tab indicator
        // Start playback; browsers may reject without prior user gesture
        try {
          _indicatorAudio!.play();
        } catch (_) {}
      } else {
        _indicatorAudio!.pause();
        _indicatorAudio!.currentTime = 0;
      }
    } catch (_) {
      // ignore
    }
  }

  static void _ensureElement() {
    if (_indicatorAudio == null) {
      _indicatorAudio = web.HTMLAudioElement();
      _indicatorAudio!.loop = true;
      _indicatorAudio!.preload = 'auto';
      _indicatorAudio!.style.display = 'none';
      // Slightly reduce CPU by setting a very short silent clip
      _audioSrc ??= _createSilentWavDataUri(sampleRate: 8000, numSamples: 8);
      _indicatorAudio!.src = _audioSrc!;
      // Start paused until asked
      _indicatorAudio!.pause();
    }
  }

  static String _createSilentWavDataUri({
    int sampleRate = 8000,
    int numChannels = 1,
    int bitsPerSample = 16,
    int numSamples = 8,
  }) {
    final bytesPerSample = bitsPerSample ~/ 8;
    final blockAlign = numChannels * bytesPerSample;
    final byteRate = sampleRate * blockAlign;
    final dataSize = numSamples * blockAlign;
    final totalSize = 44 + dataSize;
    final buffer = Uint8List(totalSize);
    final view = ByteData.view(buffer.buffer);
    var offset = 0;

    void writeString(String s) {
      for (var i = 0; i < s.length; i++) {
        buffer[offset++] = s.codeUnitAt(i);
      }
    }

    void writeUint32(int v) {
      view.setUint32(offset, v, Endian.little);
      offset += 4;
    }

    void writeUint16(int v) {
      view.setUint16(offset, v, Endian.little);
      offset += 2;
    }

    // RIFF header
    writeString('RIFF');
    writeUint32(36 + dataSize);
    writeString('WAVE');
    // fmt chunk
    writeString('fmt ');
    writeUint32(16);
    writeUint16(1); // PCM
    writeUint16(numChannels);
    writeUint32(sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(bitsPerSample);
    // data chunk
    writeString('data');
    writeUint32(dataSize);
    // body already zeroed for silence

    final base64Data = base64Encode(buffer);
    return 'data:audio/wav;base64,$base64Data';
  }
}
