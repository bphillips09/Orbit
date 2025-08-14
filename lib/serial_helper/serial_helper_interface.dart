// Serial Helper Interface, provides a platform-agnostic interface for serial communication
import 'dart:typed_data';
import 'package:orbit/serial_helper/serial_helper_stub.dart'
    if (dart.library.io) 'package:orbit/serial_helper/serial_helper_standalone.dart'
    if (dart.library.js) 'package:orbit/serial_helper/serial_helper_web.dart';

abstract class SerialHelper {
  Future<List<Object>> listPorts();
  Future<bool> openPort(Object? port, int baud);
  Future<int> writeData(Uint8List data);
  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  );
  Future<bool> closePort();
  Future<String> getPortName(Object port);
  Future<bool> ensureSerialPermission();

  factory SerialHelper() => getSerialHelper();
}
