// Telemetry class for tracking anonymous usage
import 'dart:async';

import 'telemetry_backend.dart' as backend;

class Telemetry {
  Telemetry._();

  static bool _initialized = false;
  static bool _disabled = false;
  static final Map<String, dynamic> _globalProps = <String, dynamic>{};

  static const Duration _initTimeout = Duration(seconds: 2);

  static Future<void> initialize(
    String appKey, {
    bool debug = false,
  }) async {
    if (_disabled) {
      _initialized = false;
      return;
    }
    try {
      _initialized = await backend
          .telemetryInit(appKey, debug: debug)
          .timeout(_initTimeout);
    } catch (_) {
      _initialized = false;
    }
  }

  static Future<void> event(
    String eventName, [
    Map<String, dynamic>? props,
  ]) async {
    if (!_initialized || _disabled) return;
    try {
      final Map<String, dynamic> mergedProps = {
        ..._globalProps,
        if (props != null) ...props,
      };
      // Don't block UI on telemetry
      unawaited(backend.telemetrySend(eventName, mergedProps));
    } catch (_) {}
  }

  static void setProperties(Map<String, dynamic> properties) {
    _globalProps.addAll(properties);
  }

  static void setProperty(String key, dynamic value) {
    _globalProps[key] = value;
  }

  static void removeProperty(String key) {
    _globalProps.remove(key);
  }

  static void removeProperties(Iterable<String> keys) {
    for (final key in keys) {
      _globalProps.remove(key);
    }
  }

  static void clearProperties() {
    _globalProps.clear();
  }

  static void setDisabled(bool disabled) {
    _disabled = disabled;
  }
}
