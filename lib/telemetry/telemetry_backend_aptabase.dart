import 'dart:async';

import 'package:aptabase_flutter/aptabase_flutter.dart';

const Duration _telemetryNetworkTimeout = Duration(seconds: 2);

Future<bool> telemetryInit(
  String appKey, {
  required bool debug,
}) async {
  try {
    await Aptabase.init(
      appKey,
      InitOptions(printDebugMessages: debug),
    ).timeout(_telemetryNetworkTimeout);
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
    await Aptabase.instance
        .trackEvent(eventName, props)
        .timeout(_telemetryNetworkTimeout);
  } catch (_) {}
}

