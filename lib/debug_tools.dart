import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:orbit/data/wxtab_parser.dart';
import 'package:orbit/logging.dart';

// FrameTracer, traces the frames sent and received by the device
class FrameTracer {
  FrameTracer._internal();
  static final FrameTracer instance = FrameTracer._internal();

  bool _enabled = false;
  IOSink? _sink;
  File? _file;
  static const int _maxBytes = 2 * 1024 * 1024; // 2 MB max file size
  static const int _maxRotations = 3;

  bool get isEnabled => _enabled;
  String? get traceFilePath => _file?.path;

  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled && !kIsWeb;
    if (!_enabled) {
      await _disposeSink();
      return;
    }
    await _ensureFile();
    try {
      await AppLogger.instance.ensureFileOutputReady();
    } catch (_) {}
  }

  Future<void> _ensureFile() async {
    if (kIsWeb) return;
    if (_sink != null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final logsDir = Directory(p.join(dir.path, 'logs'));
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }
      _file = File(p.join(logsDir.path, 'link_trace.log'));
      await _maybeRotate();
      _sink = _file!.openWrite(mode: FileMode.append);
      await _sink!.flush();
    } catch (_) {
      await _disposeSink();
    }
  }

  Future<void> _maybeRotate() async {
    try {
      if (_file == null) return;
      if (!await _file!.exists()) return;
      final size = await _file!.length();
      if (size < _maxBytes) return;

      await _disposeSink();

      for (int i = _maxRotations - 1; i >= 1; i--) {
        final rotated = File('${_file!.path}.$i');
        final next = File('${_file!.path}.${i + 1}');
        if (await rotated.exists()) {
          if (await next.exists()) {
            await next.delete();
          }
          await rotated.rename(next.path);
        }
      }

      final first = File('${_file!.path}.1');
      if (await first.exists()) {
        await first.delete();
      }
      await _file!.rename(first.path);
      _file = File(_file!.path); // recreate current
      await _file!.create(recursive: true);
    } catch (_) {}
  }

  Future<void> _disposeSink() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }

  String _hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

  String _formatFrame(Uint8List frame, String dir) {
    final ts = DateTime.now().toIso8601String();
    final len = frame.length;
    int seq = len > 2 ? frame[2] : -1;
    int payloadType = len > 3 ? frame[3] : -1;
    int payloadLen = len > 5 ? ((frame[4] << 8) | frame[5]) : -1;
    int opcodeMsb = len > 6 ? frame[6] : -1;
    int opcodeLsb = len > 7 ? frame[7] : -1;
    final header =
        'seq=$seq type=0x${_hex2(payloadType)} len=$payloadLen opcode=0x${_hex2(opcodeMsb)}${_hex2(opcodeLsb)}';
    final hex = frame.map((b) => _hex2(b)).join(' ');
    return '[$ts] $dir $len bytes | $header\n$hex\n';
  }

  Future<void> logRxFrame(Uint8List frame) async {
    if (!_enabled) return;
    await _ensureFile();
    if (_sink == null) return;
    try {
      await _maybeRotate();
      _sink!.write(_formatFrame(frame, 'RX'));
    } catch (_) {}
  }

  Future<void> logTxFrame(Uint8List frame) async {
    if (!_enabled) return;
    await _ensureFile();
    if (_sink == null) return;
    try {
      await _maybeRotate();
      _sink!.write(_formatFrame(frame, 'TX'));
    } catch (_) {}
  }
}

// WxTabDebugTools, parses WxTab files from hex strings
class WxTabDebugTools {
  WxTabDebugTools._internal();
  static final WxTabDebugTools instance = WxTabDebugTools._internal();

  List<int> _hexToBytes(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    final bytes = <int>[];
    for (int i = 0; i + 1 < cleaned.length; i += 2) {
      bytes.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  Future<void> parseWxTabFromHexFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        logger.w('WxTabDebug: File not found: $path');
        return;
      }
      final txt = await file.readAsString();
      final bytes = _hexToBytes(txt);
      logger.i('WxTabDebug: Read ${bytes.length} bytes from $path');
      final parsed = WxTabParser.parse(bytes,
          fileName: path.split(Platform.pathSeparator).last);
      logger.i(
          'WxTabDebug: Parsed WxTab dbVersion=${parsed.dbVersion} fileVersion=${parsed.fileVersion} versionBits=${parsed.fileVersionBits} states=${parsed.states.length}');
      if (parsed.states.isNotEmpty) {
        final s = parsed.states.first;
        logger.i(
            'WxTabDebug: First state id=${s.id} entries=${s.entries.length}');
      }
    } catch (e) {
      logger.w('WxTabDebug: Parse failed: $e');
    }
  }
}
