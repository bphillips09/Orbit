import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Android platform settings that are not tied to a specific feature module
class AndroidPlatformSettings {
  static const MethodChannel _channel = MethodChannel('com.bp.orbit/platform');

  static bool get isAvailable =>
      !kIsWeb && !kIsWasm && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> playStartupSilence() async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('playStartupSilence');
  }
}
