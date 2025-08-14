// Web-only implementation to clear caches and force a reload
import 'package:web/web.dart' as web;
import 'package:flutter/material.dart';

Future<void> invalidateCachesAndReload(BuildContext context) async {
  try {
    // Add a cache-busting query param and reload
    final current = web.window.location.href;
    final uri = Uri.parse(current);
    final newParams = Map<String, String>.from(uri.queryParameters);
    newParams['t'] = DateTime.now().millisecondsSinceEpoch.toString();
    final refreshed = uri.replace(queryParameters: newParams).toString();
    web.window.location.replace(refreshed);
  } catch (_) {
    // Fallback to a hard reload
    web.window.location.reload();
  }
}
