// Serial Helper for Standalone Platforms
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:orbit/logging.dart';

// Serial Helper for Standalone Platforms
class StandaloneSerialHelper implements SerialHelper {
  late SerialPort _serialPort;
  late SerialPortReader _reader;

  UsbDevice? _androidDevice;
  UsbPort? _androidPort;
  bool _requestedAndroidUsbPermission = false;

  bool expectedClosure = false;

  @override
  Future<List<Object>> listPorts() async {
    if (Platform.isAndroid) {
      var devices = await UsbSerial.listDevices();
      return devices.map((dev) => dev.productName ?? dev.deviceName).toList();
    } else {
      return SerialPort.availablePorts;
    }
  }

  @override
  Future<bool> openPort(Object? port, int baud) async {
    if (Platform.isAndroid) {
      logger.d('Opening port on Mobile');

      var selectedDevice = (port as String? ?? '');
      var allDevices = await UsbSerial.listDevices();

      for (var dev in allDevices) {
        if (dev.productName == selectedDevice ||
            dev.deviceName == selectedDevice) {
          _androidDevice = dev;
          break;
        }
      }

      if (_androidDevice == null) {
        logger.d('No Android Device');
        return false;
      }

      _androidPort = await _androidDevice!.create();

      bool openResult = await _androidPort!.open();
      if (!openResult) {
        logger.d('Cannot open the device');
        return false;
      }

      _androidPort!.setPortParameters(
          baud, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    } else {
      logger.d('Opening port on Desktop');

      _serialPort = SerialPort(port as String? ?? '');

      if (_serialPort.isOpen) {
        return true;
      }

      if (!_serialPort.openReadWrite()) {
        return false;
      }

      var config = _serialPort.config;
      config
        ..baudRate = baud
        ..bits = 8
        ..parity = SerialPortParity.none
        ..stopBits = 1
        ..xonXoff = 0
        ..rts = 0
        ..dtr = 0;

      _serialPort.config = config;
      config.dispose();
    }

    expectedClosure = false;

    return true;
  }

  @override
  Future<bool> ensureSerialPermission() async {
    if (!Platform.isAndroid) return true;
    if (_requestedAndroidUsbPermission) return true;
    final devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      // Nothing to request yet; leave flag false so we can try again later.
      return true;
    }
    try {
      final tempPort = await devices.first.create();
      try {
        await tempPort?.close();
      } catch (_) {}
      _requestedAndroidUsbPermission = true;
      return true;
    } catch (_) {
      // user may deny
      _requestedAndroidUsbPermission = true;
      return false;
    }
  }

  @override
  Future<int> writeData(Uint8List data) async {
    if (Platform.isAndroid) {
      if (_androidPort == null) {
        logger.d('Android port not available');
        return 1;
      }
      await _androidPort!.write(data);
      return 0;
    } else {
      if (!_serialPort.isOpen) {
        logger.d('Serial port not open');
        return 1;
      }
      return _serialPort.write(data);
    }
  }

  @override
  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) async {
    if (Platform.isAndroid) {
      if (_androidPort == null) {
        logger.d('Android port not available');
        return;
      }

      try {
        _androidPort!.inputStream?.listen(onData);
      } catch (e) {
        logger.d("Port Error: $e");
        onEnd('Port Error: $e', false);
      }
    } else {
      if (!_serialPort.isOpen) {
        return;
      }

      _reader = SerialPortReader(_serialPort);

      try {
        _reader.stream.listen(
          onData,
          onError: (err) {
            onEnd(err, expectedClosure);
          },
          onDone: () {
            onEnd('Done', true);
          },
          cancelOnError: true,
        );
      } catch (e) {
        logger.d("Port Error: $e");
        onEnd('Port Error: $e', false);
      }
    }
  }

  @override
  Future<bool> closePort() async {
    if (Platform.isAndroid) {
      logger.d('Closing port on Mobile');
      if (_androidPort == null) {
        logger.d('Android port not available');
        return false;
      }

      return await _androidPort!.close();
    } else {
      logger.d('Closing port on Desktop');
      if (!_serialPort.isOpen) {
        return true;
      }

      int timeout = 5;
      while (_serialPort.isOpen && timeout > 0) {
        expectedClosure = true;
        _serialPort.close();
        await Future.delayed(const Duration(seconds: 1));
        timeout--;
      }

      return _serialPort.close();
    }
  }

  @override
  Future<String> getPortName(Object port) async {
    if (Platform.isAndroid) {
      var devices = await UsbSerial.listDevices();
      for (var device in devices) {
        if (device == port) {
          return device.productName ?? device.deviceName;
        }
      }

      return '';
    } else {
      return port.toString();
    }
  }
}

SerialHelper getSerialHelper() => StandaloneSerialHelper();
