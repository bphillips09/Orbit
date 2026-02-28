// Serial Helper for Web UART
// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:orbit/logging.dart';
import 'package:serial/serial.dart';
import 'package:web/web.dart' as web;

class WebUartHelper {
  SerialPort? _serialPort;
  web.WritableStreamDefaultWriter? writer;
  web.ReadableStreamDefaultReader? reader;
  bool read = false;

  Future<List<Object>> listPorts() async {
    final ports = await web.window.navigator.serial.getPorts().toDart;
    return ports.toDart;
  }

  Future<bool> openPort(Object? port, int baud) async {
    try {
      if (_serialPort == null) {
        if (port == null || port == '') {
          _serialPort = await web.window.navigator.serial.requestPort().toDart;
        } else {
          _serialPort = port as SerialPort;
        }
      }
      if (_serialPort == null) return false;
      await _serialPort!.open(baudRate: baud).toDart;
      writer = null;
      reader = null;
      return true;
    } catch (e) {
      logger.e('Error opening web UART port: $e');
      return false;
    }
  }

  Future<bool> reconfigureBaud(int baud) async {
    if (_serialPort == null) return false;
    logger.w('In-place baud reconfiguration is not supported on Web');
    return false;
  }

  Future<int> writeData(Uint8List data) async {
    if (_serialPort == null) return -1;
    writer ??= _serialPort?.writable?.getWriter();
    try {
      await writer?.ready.toDart;
      await writer?.write(data.toJS).toDart;
    } catch (e) {
      logger.e('Error writing web UART data: $e');
      try {
        writer?.releaseLock();
      } catch (_) {
        await writer?.abort().toDart;
      }
    }
    return 0;
  }

  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) async {
    read = true;
    while (_serialPort != null && read) {
      reader =
          _serialPort?.readable?.getReader() as web.ReadableStreamDefaultReader;
      try {
        while (true) {
          final result = await reader?.read().toDart;
          if (result!.done) {
            onEnd('Done', true);
            break;
          }
          final value = result.value;
          if (value != null && value.isA<JSUint8Array>()) {
            final data = value as JSUint8Array;
            onData(data.toDart);
          }
        }
      } catch (error) {
        onEnd(error, false);
      } finally {
        reader?.releaseLock();
      }
    }
    read = false;
  }

  Future<bool> closePort() async {
    if (_serialPort != null) {
      try {
        if (_serialPort!.readable?.locked == true) {
          read = false;
          await reader?.cancel().toDart;
        }
        if (_serialPort!.writable?.locked == true) {
          try {
            writer?.releaseLock();
            if (_serialPort!.writable?.locked == true) {
              await writer?.abort().toDart;
            }
          } catch (_) {
            await writer?.abort().toDart;
          }
        }
        await _serialPort?.close().toDart;
      } catch (_) {
        await _serialPort?.close().toDart;
        return false;
      } finally {
        writer = null;
        reader = null;
      }
    }
    return true;
  }

  Future<String> getPortName(Object port) async {
    final portInfo = (port as SerialPort?)?.getInfo();
    if (portInfo != null) {
      return 'Vendor: ${portInfo.usbVendorId}, Product: ${portInfo.usbProductId}';
    }
    return '';
  }

  Future<bool> ensureSerialPermission() async {
    try {
      await web.window.navigator.serial.requestPort().toDart;
      return true;
    } catch (e) {
      logger.w('Serial permission request failed: $e');
      return false;
    }
  }
}
