// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

// Reload the page to reinitialize the app after config import
Never requestAppRestart() {
  try {
    html.window.location.reload();
  } catch (_) {
    html.window.location.href = html.window.location.href;
  }
  // If the browser blocks reload/navigation, don't continue with stale state
  throw StateError('Restart requested');
}
