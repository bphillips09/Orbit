import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

class WelcomeDialog extends StatelessWidget {
  final VoidCallback onGetStarted;
  const WelcomeDialog({super.key, required this.onGetStarted});

  static Future<void> show(
      BuildContext context, VoidCallback onGetStarted) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => WelcomeDialog(onGetStarted: onGetStarted),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurfaceColor = theme.colorScheme.onSurface;
    final linkColor = theme.colorScheme.primary;

    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Expanded(child: Text('Welcome to Orbit')),
          Image.asset('assets/icon/icon.png', width: 32, height: 32),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Orbit is an offline satellite radio player.',
              style: TextStyle(fontSize: 16, color: onSurfaceColor),
            ),
            const SizedBox(height: 16),
            Text(
              'An SXV300 tuner is required.',
              style: TextStyle(fontSize: 16, color: onSurfaceColor),
            ),
            if (kIsWeb) ...[
              const SizedBox(height: 24),
              RichText(
                text: TextSpan(
                  style: TextStyle(fontSize: 16, color: onSurfaceColor),
                  children: [
                    const TextSpan(
                      text: 'Native versions of Orbit can be downloaded ',
                    ),
                    TextSpan(
                      text: 'here',
                      style: TextStyle(
                          color: linkColor,
                          decoration: TextDecoration.underline),
                      recognizer: TapGestureRecognizer()
                        ..onTap = () {
                          launchUrl(
                            Uri.parse(
                                'https://github.com/bphillips09/orbit/releases/latest'),
                            webOnlyWindowName: '_blank',
                          );
                        },
                    ),
                    const TextSpan(text: '.'),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            onGetStarted();
            Navigator.of(context).pop();
          },
          child: const Text('Get Started'),
        ),
      ],
    );
  }
}
