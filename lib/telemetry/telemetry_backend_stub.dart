Future<bool> telemetryInit(
  String appKey, {
  required bool debug,
}) async {
  return false;
}

Future<void> telemetrySend(
  String eventName,
  Map<String, dynamic> props,
) async {
  // No-op
}
