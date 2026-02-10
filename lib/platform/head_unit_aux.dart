import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:orbit/logging.dart';

// Head unit native aux input switching helpers
class HeadUnitAux {
  static const MethodChannel _channel = MethodChannel('com.bp.orbit/head_unit');

  static bool get isAvailable =>
      !kIsWeb && !kIsWasm && defaultTargetPlatform == TargetPlatform.android;

  // Switch the head unit to aux input
  static Future<int> switchToAux({int timeoutMs = 1500}) async {
    if (!isAvailable) {
      throw UnsupportedError('Head unit aux input switching is Android-only.');
    }
    final appId = await _channel.invokeMethod<int>(
      'switchToAux',
      {'timeoutMs': timeoutMs},
    );
    if (appId == null) {
      throw PlatformException(
          code: 'NULL_RESULT', message: 'switchToAux returned null');
    }
    return appId;
  }

  static String describeError(Object error) {
    if (error is PlatformException) {
      final msg = (error.message ?? '').trim();
      final details = (error.details?.toString() ?? '').trim();
      final parts = <String>[
        error.code,
        if (msg.isNotEmpty) msg,
        if (details.isNotEmpty) details,
      ];
      return parts.join(': ');
    }
    return error.toString();
  }

  // Wrapper that logs and returns (appId, errorMessage)
  static Future<({int? appId, String? errorMessage})> trySwitchToAux(
      {int timeoutMs = 1500}) async {
    if (!isAvailable) {
      return (appId: null, errorMessage: 'Not supported on this platform.');
    }
    try {
      final id = await switchToAux(timeoutMs: timeoutMs);
      logger.i('HeadUnitAux: switched to aux input');
      return (appId: id, errorMessage: null);
    } catch (e, st) {
      final msg = describeError(e);
      logger.e('HeadUnitAux: failed to switch to aux input',
          error: e, stackTrace: st);
      return (appId: null, errorMessage: msg);
    }
  }
}
