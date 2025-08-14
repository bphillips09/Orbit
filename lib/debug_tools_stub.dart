// FrameTracer, a stub for the FrameTracer class
import 'dart:typed_data';

class FrameTracer {
  FrameTracer._internal();
  static final FrameTracer instance = FrameTracer._internal();

  bool get isEnabled => false;
  String? get traceFilePath => null;

  Future<void> setEnabled(bool enabled) async {}
  Future<void> logRxFrame(Uint8List frame) async {}
  Future<void> logTxFrame(Uint8List frame) async {}
}
