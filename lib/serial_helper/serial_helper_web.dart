// Serial Helper for Web Platforms
// ignore: avoid_web_libraries_in_flutter
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:serial/serial.dart';
import 'package:web/web.dart' as web;
import 'package:orbit/logging.dart';

class WebSerialHelper implements SerialHelper {
  SerialPort? _serialPort;
  web.WritableStreamDefaultWriter? writer;
  web.ReadableStreamDefaultReader? reader;
  bool read = false;

  @override
  Future<List<Object>> listPorts() async {
    var ports = await web.window.navigator.serial.getPorts().toDart;
    logger.d('Listing ports: $ports');
    return ports.toDart;
  }

  @override
  Future<bool> openPort(
    Object? port,
    int baud, {
    SerialTransport transport = SerialTransport.serial,
  }) async {
    if (transport == SerialTransport.network) {
      logger.w('Network transport is not supported on Web');
      return false;
    }
    logger.i('Opening port (${port ?? "none"}) on Web at $baud baud');

    try {
      if (_serialPort == null) {
        if (port == null || port == '') {
          _serialPort = await web.window.navigator.serial.requestPort().toDart;
        } else {
          _serialPort = port as SerialPort;
        }
      }

      if (_serialPort == null) {
        logger.w('No port selected');
        return false;
      }

      await _serialPort!.open(baudRate: baud).toDart;

      // Reset writer and reader to ensure proper reinitialization
      writer = null;
      reader = null;

      return true;
    } catch (e) {
      logger.e('Error opening port: $e');
      return false;
    }
  }

  @override
  Future<int> writeData(Uint8List data) async {
    if (_serialPort == null) {
      logger.w('Port not open');
      return 0;
    }

    writer ??= _serialPort?.writable?.getWriter();

    try {
      await writer?.ready.toDart;
      await writer?.write(data.toJS).toDart;
    } catch (e) {
      logger.e('Error writing data: $e');
      try {
        writer?.releaseLock();
      } catch (e) {
        logger.w('Error releasing writer: $e');
        await writer?.abort().toDart;
      }
    }

    return 0;
  }

  @override
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
            logger.d('Stream reader closed');
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
        logger.e(error.toString());
        onEnd(error, false);
      } finally {
        logger.d('Releasing reader lock');
        reader?.releaseLock();
      }
    }

    logger.d('Stopped reading');
    read = false;
  }

  @override
  Future<bool> closePort() async {
    logger.i('Closing port on Web');
    if (_serialPort != null) {
      try {
        if (_serialPort!.readable?.locked == true) {
          logger.d('Cancelling reader');
          read = false;
          await reader?.cancel().toDart;
          logger.d('Reader cancel completed');
        }
        if (_serialPort!.writable?.locked == true) {
          logger.d('Releasing writer lock');
          try {
            writer?.releaseLock();
            if (_serialPort!.writable?.locked == true) {
              await writer?.abort().toDart;
            }
          } catch (e) {
            logger.w('Unable to release writer lock: $e');
            logger.w('Aborting writer');
            await writer?.abort().toDart;
            logger.d('Writer abort completed');
          }
        }

        logger.d('Closing port');
        await _serialPort?.close().toDart;
        logger.d('Port closed');
      } catch (e) {
        await _serialPort?.close().toDart;
        logger.e('Error closing port: $e');
        return false;
      } finally {
        // Reset writer and reader on port closure
        writer = null;
        reader = null;
      }
    }
    return true;
  }

  @override
  Future<String> getPortName(Object port) async {
    var portInfo = (port as SerialPort?)?.getInfo();
    if (portInfo != null) {
      return 'Vendor: ${portInfo.usbVendorId}, Product: ${portInfo.usbProductId}';
    }

    return '';
  }

  @override
  Future<bool> ensureSerialPermission() async {
    try {
      await web.window.navigator.serial.requestPort().toDart;
      return true;
    } catch (e) {
      // User cancelled or the browser blocked the request
      logger.w('Serial permission request failed: $e');
      return false;
    }
  }
}

SerialHelper getSerialHelper() => WebSerialHelper();
