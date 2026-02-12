import 'dart:convert';
import 'dart:async';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:web/web.dart' as web;

String? _appKey;
Uri? _apiUrl;
Future<Map<String, dynamic>>? _systemPropsFuture;

const Duration _telemetryNetworkTimeout = Duration(seconds: 2);

// Session handling
const Duration _sessionTimeout = Duration(hours: 1);
String _sessionId = _newSessionId();
DateTime _lastTouch = DateTime.now().toUtc();

Future<bool> telemetryInit(
  String appKey, {
  required bool debug,
}) async {
  final uri = _apiUrlFromAppKey(appKey);
  if (uri == null) return false;
  _appKey = appKey;
  _apiUrl = uri;
  _systemPropsFuture ??= _computeSystemProps();
  return true;
}

Future<void> telemetrySend(
  String eventName,
  Map<String, dynamic> props,
) async {
  final key = _appKey;
  final url = _apiUrl;
  if (key == null || url == null) return;

  final now = DateTime.now().toUtc();
  final systemProps = await (_systemPropsFuture ??= _computeSystemProps());

  final payload = [
    {
      'timestamp': now.toIso8601String(),
      'sessionId': _evalSessionId(now),
      'eventName': eventName,
      'systemProps': systemProps,
      'props': props,
    }
  ];

  try {
    await http
        .post(
      url,
      headers: {
        'App-Key': key,
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(payload),
    )
        .timeout(_telemetryNetworkTimeout);
  } catch (_) {
    // Never fail due to telemetry
  }
}

Uri? _apiUrlFromAppKey(String appKey) {
  final parts = appKey.split('-');
  if (parts.length != 3) return null;

  final region = parts[1];
  final String? baseUrl = switch (region) {
    'EU' => 'https://eu.aptabase.com',
    'US' => 'https://us.aptabase.com',
    _ => null,
  };
  if (baseUrl == null) return null;
  return Uri.parse('$baseUrl/api/v0/events');
}

String _evalSessionId(DateTime now) {
  if (now.difference(_lastTouch) > _sessionTimeout) {
    _sessionId = _newSessionId();
  }
  _lastTouch = now;
  return _sessionId;
}

String _newSessionId() {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final rnd = Random();
  return List.generate(22, (_) => alphabet[rnd.nextInt(alphabet.length)])
      .join();
}

Future<Map<String, dynamic>> _computeSystemProps() async {
  final deviceInfo = DeviceInfoPlugin();
  final info = await deviceInfo.webBrowserInfo;
  final packageInfo = await PackageInfo.fromPlatform();

  final rawOsVersion = (info.appVersion ?? '').toString();
  final osVersion =
      rawOsVersion.length > 100 ? rawOsVersion.substring(0, 100) : rawOsVersion;

  return {
    'isDebug': kDebugMode,
    'osName': info.browserName.name,
    'osVersion': osVersion,
    'locale': _platformLocaleName(),
    'appVersion': packageInfo.version,
    'appBuildNumber': packageInfo.buildNumber,
    'sdkVersion': 'aptabase_flutter@0.4.1',
  };
}

String _platformLocaleName() {
  try {
    final lang = web.window.navigator.language;
    if (lang.trim().isNotEmpty) {
      return lang;
    }
  } catch (_) {}
  return 'en-US';
}
