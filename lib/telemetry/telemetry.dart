// Telemetry class for tracking anonymous usage
import 'package:aptabase_flutter/aptabase_flutter.dart';

class Telemetry {
  Telemetry._();

  static bool _initialized = false;
  static bool _disabled = false;
  static final Map<String, dynamic> _globalProps = <String, dynamic>{};

  static Future<void> initialize(
    String appKey, {
    bool debug = false,
  }) async {
    if (_disabled) {
      _initialized = false;
      return;
    }
    try {
      await Aptabase.init(
        appKey,
        InitOptions(printDebugMessages: debug),
      );
      _initialized = true;
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
      await Aptabase.instance.trackEvent(eventName, mergedProps);
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
