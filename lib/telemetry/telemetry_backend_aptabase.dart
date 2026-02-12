import 'package:aptabase_flutter/aptabase_flutter.dart';

Future<bool> telemetryInit(
  String appKey, {
  required bool debug,
}) async {
  try {
    await Aptabase.init(
      appKey,
      InitOptions(printDebugMessages: debug),
    );
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> telemetrySend(
  String eventName,
  Map<String, dynamic> props,
) async {
  try {
    await Aptabase.instance.trackEvent(eventName, props);
  } catch (_) {}
}

