// Serial Helper for Standalone UART
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:orbit/logging.dart';
import 'package:usb_serial/usb_serial.dart';

class StandaloneUartHelper {
  late SerialPort _serialPort;
  late SerialPortReader _reader;

  UsbDevice? _androidDevice;
  UsbPort? _androidPort;
  bool _requestedAndroidUsbPermission = false;
  bool _desktopOpen = false;
  bool _expectedClosure = false;
  String? _lastError;

  String? get lastError => _lastError;

  Future<List<Object>> listPorts() async {
    if (Platform.isAndroid) {
      final devices = await UsbSerial.listDevices();
      return devices.map((dev) => dev.productName ?? dev.deviceName).toList();
    }
    return SerialPort.availablePorts;
  }

  Future<bool> openPort(Object? port, int baud) async {
    _lastError = null;
    _expectedClosure = false;
    if (Platform.isAndroid) {
      try {
        final selectedDevice = (port ?? '').toString();
        final allDevices = await UsbSerial.listDevices();
        _androidDevice = null;
        for (final dev in allDevices) {
          if (dev.productName == selectedDevice ||
              dev.deviceName == selectedDevice) {
            _androidDevice = dev;
            break;
          }
        }
        if (_androidDevice == null) {
          _lastError =
              'Device "$selectedDevice" not found. Enumerated ${allDevices.length} USB serial device(s).';
          return false;
        }
        _androidPort = await _androidDevice!.create();
        if (_androidPort == null) {
          _lastError = 'Failed to create Android USB serial port handle.';
          return false;
        }
        final openResult = await _androidPort!.open();
        if (!openResult) {
          _lastError =
              'Android USB serial open() returned false for "$selectedDevice".';
          return false;
        }
        await _androidPort!.setPortParameters(
          baud,
          UsbPort.DATABITS_8,
          UsbPort.STOPBITS_1,
          UsbPort.PARITY_NONE,
        );
        return true;
      } catch (e) {
        _lastError = 'Android UART open exception: $e';
        logger.e(_lastError!);
        return false;
      }
    }

    try {
      final selectedPort = (port ?? '').toString();
      _serialPort = SerialPort(selectedPort);
      if (_serialPort.isOpen) return true;
      if (!_serialPort.openReadWrite()) {
        _lastError = _describeDesktopOpenFailure(selectedPort, baud);
        logger.e(_lastError!);
        return false;
      }

      final config = _serialPort.config;
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
      _desktopOpen = true;
      return true;
    } catch (e) {
      _lastError = 'UART open exception: $e';
      logger.e(_lastError!);
      return false;
    }
  }

  Future<bool> ensureSerialPermission() async {
    if (!Platform.isAndroid) return true;
    if (_requestedAndroidUsbPermission) return true;
    final devices = await UsbSerial.listDevices();
    if (devices.isEmpty) return true;
    try {
      final tempPort = await devices.first.create();
      try {
        await tempPort?.close();
      } catch (_) {}
      _requestedAndroidUsbPermission = true;
      return true;
    } catch (_) {
      _requestedAndroidUsbPermission = true;
      return false;
    }
  }

  Future<bool> reconfigureBaud(int baud) async {
    try {
      if (Platform.isAndroid) {
        if (_androidPort == null) return false;
        await _androidPort!.setPortParameters(
          baud,
          UsbPort.DATABITS_8,
          UsbPort.STOPBITS_1,
          UsbPort.PARITY_NONE,
        );
        return true;
      }
      if (!_desktopOpen || !_serialPort.isOpen) return false;
      final config = _serialPort.config;
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
      return true;
    } catch (e) {
      _lastError = 'Failed to reconfigure UART baud: $e';
      logger.w(_lastError!);
      return false;
    }
  }

  Future<int> writeData(Uint8List data) async {
    if (Platform.isAndroid) {
      if (_androidPort == null) return -1;
      await _androidPort!.write(data);
      return 0;
    }
    if (!_desktopOpen || !_serialPort.isOpen) return -1;
    return _serialPort.write(data);
  }

  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) async {
    if (Platform.isAndroid) {
      if (_androidPort == null) return;
      try {
        _androidPort!.inputStream?.listen(onData);
      } catch (e) {
        onEnd('Port Error: $e', false);
      }
      return;
    }
    if (!_desktopOpen || !_serialPort.isOpen) return;
    _reader = SerialPortReader(_serialPort);
    try {
      _reader.stream.listen(
        onData,
        onError: (err) => onEnd(err, _expectedClosure),
        onDone: () => onEnd('Done', true),
        cancelOnError: true,
      );
    } catch (e) {
      onEnd('Port Error: $e', false);
    }
  }

  String _describeDesktopOpenFailure(String port, int baud) {
    final details = <String>[
      'UART openReadWrite() returned false for "$port" at $baud baud.'
    ];
    try {
      final dynamic dynPort = _serialPort;
      final dynamic code = dynPort.lastError;
      if (code != null) {
        details.add('libserialport code: $code');
      }
    } catch (_) {}
    return details.join(' ');
  }

  Future<bool> closePort() async {
    if (Platform.isAndroid) {
      if (_androidPort == null) return false;
      _expectedClosure = true;
      return _androidPort!.close();
    }

    if (!_desktopOpen) return true;
    if (!_serialPort.isOpen) {
      _desktopOpen = false;
      return true;
    }

    var timeout = 5;
    while (_serialPort.isOpen && timeout > 0) {
      _expectedClosure = true;
      _serialPort.close();
      await Future.delayed(const Duration(seconds: 1));
      timeout--;
    }
    _desktopOpen = false;
    return _serialPort.close();
  }

  Future<String> getPortName(Object port) async {
    if (Platform.isAndroid) {
      final devices = await UsbSerial.listDevices();
      for (final device in devices) {
        if (device == port) {
          return device.productName ?? device.deviceName;
        }
      }
      return '';
    }
    return port.toString();
  }
}
