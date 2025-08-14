// Unsupported Browser warning for Web
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

class UnsupportedBrowserApp extends StatelessWidget {
  const UnsupportedBrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unsupported Browser',
      themeMode: ThemeMode.system,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      home: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final onSurfaceColor = theme.colorScheme.onSurface;
          final linkColor = theme.colorScheme.primary;
          return Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 600),
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.usb_off, size: 64),
                      const SizedBox(height: 16),
                      Text('Browser Not Supported',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: onSurfaceColor,
                          ),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      RichText(
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: TextStyle(
                            fontSize: 16,
                            color: onSurfaceColor,
                          ),
                          children: [
                            const TextSpan(
                                text:
                                    'This app only supports Chromium-based browsers on Desktop platforms.\n\nPlease use '),
                            TextSpan(
                              text: 'Chrome',
                              style: TextStyle(
                                color: linkColor,
                                decoration: TextDecoration.underline,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  launchUrl(
                                    Uri.parse('https://www.google.com/chrome/'),
                                    webOnlyWindowName: '_blank',
                                  );
                                },
                            ),
                            const TextSpan(text: ', '),
                            TextSpan(
                              text: 'Edge',
                              style: TextStyle(
                                color: linkColor,
                                decoration: TextDecoration.underline,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  launchUrl(
                                    Uri.parse(
                                        'https://www.microsoft.com/en-us/edge/'),
                                    webOnlyWindowName: '_blank',
                                  );
                                },
                            ),
                            const TextSpan(text: ', or '),
                            TextSpan(
                              text: 'Opera',
                              style: TextStyle(
                                color: linkColor,
                                decoration: TextDecoration.underline,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () {
                                  launchUrl(
                                    Uri.parse('https://www.opera.com/'),
                                    webOnlyWindowName: '_blank',
                                  );
                                },
                            ),
                            const TextSpan(text: '.'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
