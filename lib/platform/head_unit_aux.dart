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

  // Exit aux input
  static Future<bool> exitAux({int timeoutMs = 1500}) async {
    if (!isAvailable) {
      throw UnsupportedError('Head unit aux input switching is Android-only.');
    }
    final exited = await _channel.invokeMethod<bool>(
      'exitAux',
      {'timeoutMs': timeoutMs},
    );
    if (exited == null) {
      throw PlatformException(
          code: 'NULL_RESULT', message: 'exitAux returned null');
    }
    return exited;
  }

  // Whether the current input is aux
  static Future<bool> isCurrentInputAux({int timeoutMs = 1500}) async {
    if (!isAvailable) {
      throw UnsupportedError('Head unit aux input is Android-only');
    }
    final isAux = await _channel.invokeMethod<bool>(
      'isCurrentInputAux',
      {'timeoutMs': timeoutMs},
    );
    if (isAux == null) {
      throw PlatformException(
          code: 'NULL_RESULT', message: 'isCurrentInputAux returned null');
    }
    return isAux;
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

  // Wrapper that logs and returns (exited, errorMessage)
  static Future<({bool exited, String? errorMessage})> tryExitAux(
      {int timeoutMs = 1500}) async {
    if (!isAvailable) {
      return (exited: false, errorMessage: 'Not supported on this platform.');
    }
    try {
      final exited = await exitAux(timeoutMs: timeoutMs);
      if (exited) {
        logger.i('HeadUnitAux: exited aux input');
      } else {
        logger
            .w('HeadUnitAux: aux input may still be active after exit request');
        return (
          exited: false,
          errorMessage: 'Aux input did not exit',
        );
      }
      return (exited: exited, errorMessage: null);
    } catch (e, st) {
      final msg = describeError(e);
      logger.e('HeadUnitAux: failed to exit aux input',
          error: e, stackTrace: st);
      return (exited: false, errorMessage: msg);
    }
  }

  static Future<({bool isAux, String? errorMessage})> tryIsCurrentInputAux(
      {int timeoutMs = 1500}) async {
    if (!isAvailable) {
      return (isAux: false, errorMessage: 'Not supported on this platform.');
    }
    try {
      final isAux = await isCurrentInputAux(timeoutMs: timeoutMs);
      return (isAux: isAux, errorMessage: null);
    } catch (e) {
      return (isAux: false, errorMessage: describeError(e));
    }
  }
}
