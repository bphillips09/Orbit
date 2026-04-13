export 'web_serial_support_stub.dart'
    if (dart.library.js_interop) 'web_serial_support_web.dart'
    if (dart.library.html) 'web_serial_support_web.dart'
    if (dart.library.js) 'web_serial_support_web.dart';
