// Serial Helper for Web
import 'dart:typed_data';
import 'package:orbit/logging.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:orbit/serial_helper/serial_helper_web_uart.dart';

class WebSerialHelper implements SerialHelper {
  final WebUartHelper _uart = WebUartHelper();

  @override
  Future<List<Object>> listPorts() => _uart.listPorts();

  @override
  Future<bool> openPort(
    Object? port,
    int baud, {
    SerialTransport transport = SerialTransport.serial,
  }) {
    if (transport != SerialTransport.serial) {
      logger.w('Web supports only UART transport');
      return Future.value(false);
    }
    return _uart.openPort(port, baud);
  }

  @override
  Future<int> writeData(Uint8List data) => _uart.writeData(data);

  @override
  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) =>
      _uart.readData(onData, onEnd);

  @override
  Future<bool> closePort() => _uart.closePort();

  @override
  Future<bool> reconfigureBaud(
    int baud, {
    SerialTransport transport = SerialTransport.serial,
  }) {
    if (transport != SerialTransport.serial) {
      logger.w('Web supports only UART transport');
      return Future.value(false);
    }
    return _uart.reconfigureBaud(baud);
  }

  @override
  Future<String> getPortName(Object port) => _uart.getPortName(port);

  @override
  Future<bool> ensureSerialPermission() => _uart.ensureSerialPermission();

  @override
  String? getLastError() => _uart.lastError;
}

SerialHelper getSerialHelper() => WebSerialHelper();
