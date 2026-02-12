import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:orbit/logging.dart';

// Head unit native aux input switching helpers
class HeadUnitAux {
  static const MethodChannel _channel = MethodChannel('com.bp.orbit/head_unit');

  static bool get isAvailable =>
      !kIsWeb && !kIsWasm && defaultTargetPlatform == TargetPlatform.android;

  // Switch the head unit to aux input
  static Future<bool> switchToAux({int timeoutMs = 1500}) async {
    if (!isAvailable) {
      throw UnsupportedError('Head unit aux input switching is Android-only.');
    }
    final opened = await _channel.invokeMethod<bool>(
      'switchToAux',
      {'timeoutMs': timeoutMs},
    );
    if (opened == null) {
      throw PlatformException(
          code: 'NULL_RESULT', message: 'switchToAux returned null');
    }
    return opened;
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

  // Wrapper that logs and returns (opened, errorMessage)
  static Future<({bool opened, String? errorMessage})> trySwitchToAux(
      {int timeoutMs = 1500}) async {
    if (!isAvailable) {
      return (opened: false, errorMessage: 'Not supported on this platform.');
    }
    try {
      final opened = await switchToAux(timeoutMs: timeoutMs);
      if (opened) {
        logger.i('HeadUnitAux: switched to aux input');
      } else {
        logger.w(
            'HeadUnitAux: aux input did not become active after switch request');
        return (
          opened: false,
          errorMessage: 'Aux input did not become active',
        );
      }
      return (opened: opened, errorMessage: null);
    } catch (e, st) {
      final msg = describeError(e);
      logger.e('HeadUnitAux: failed to switch to aux input',
          error: e, stackTrace: st);
      return (opened: false, errorMessage: msg);
    }
  }
}
