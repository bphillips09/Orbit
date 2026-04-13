import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

bool browserSupportsWebSerial() {
  try {
    return web.window.navigator.hasProperty('serial'.toJS).toDart;
  } catch (_) {
    return false;
  }
}
