// Serial Helper for Standalone Platforms
import 'dart:typed_data';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:orbit/serial_helper/serial_helper_standalone_uart.dart';
import 'package:orbit/serial_helper/serial_helper_standalone_uartip.dart';

class StandaloneSerialHelper implements SerialHelper {
  final StandaloneUartHelper _uart = StandaloneUartHelper();
  final StandaloneUartIpHelper _uartip = StandaloneUartIpHelper();
  SerialTransport _activeTransport = SerialTransport.serial;

  @override
  Future<List<Object>> listPorts() => _uart.listPorts();

  @override
  Future<bool> openPort(
    Object? port,
    int baud, {
    SerialTransport transport = SerialTransport.serial,
  }) async {
    _activeTransport = transport;
    switch (transport) {
      case SerialTransport.serial:
        return _uart.openPort(port, baud);
      case SerialTransport.network:
        return _uartip.openPort(port, baud);
    }
  }

  @override
  Future<int> writeData(Uint8List data) {
    if (_activeTransport == SerialTransport.network) {
      return _uartip.writeData(data);
    }
    return _uart.writeData(data);
  }

  @override
  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) {
    if (_activeTransport == SerialTransport.network) {
      return _uartip.readData(onData, onEnd);
    }
    return _uart.readData(onData, onEnd);
  }

  @override
  Future<bool> closePort() {
    if (_activeTransport == SerialTransport.network) {
      return _uartip.closePort();
    }
    return _uart.closePort();
  }

  @override
  Future<bool> reconfigureBaud(
    int baud, {
    SerialTransport transport = SerialTransport.serial,
  }) {
    if (transport == SerialTransport.network) {
      return _uartip.reconfigureBaud(baud);
    }
    return _uart.reconfigureBaud(baud);
  }

  @override
  Future<String> getPortName(Object port) {
    if (_activeTransport == SerialTransport.network) {
      return Future.value(port.toString());
    }
    return _uart.getPortName(port);
  }

  @override
  Future<bool> ensureSerialPermission() => _uart.ensureSerialPermission();
}

SerialHelper getSerialHelper() => StandaloneSerialHelper();
