// Checks GitHub for the latest release and prompts the user if an update is available.
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:orbit/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:version/version.dart';
import 'update_reload_stub.dart'
    if (dart.library.html) 'update_reload_web.dart';

Future<void> checkForAppUpdates(
  BuildContext context, {
  String owner = 'bphillips09',
  String repo = 'orbit',
}) async {
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = Version.parse(packageInfo.version);

    final uri = Uri.parse(
      'https://api.github.com/repos/$owner/$repo/releases/latest',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 5));

    if (response.statusCode != 200) {
      logger.w(
          'Update check failed: ${response.statusCode} ${response.reasonPhrase}');
      return;
    }

    final dynamic data = jsonDecode(response.body);
    final String rawTag = (data['tag_name'] ?? '').toString();
    if (rawTag.isEmpty) return;

    final latestVersion = Version.parse(rawTag.replaceAll('v', ''));
    final String downloadUrl = (data['html_url'] ?? '').toString();

    if (latestVersion > currentVersion && downloadUrl.isNotEmpty) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Update Available'),
            content: Text(
              'A new version is available.\nDo you want to update?\n\n'
              'v${currentVersion.toString()} → v${latestVersion.toString()}',
            ),
            actions: <Widget>[
              TextButton(
                child: const Text('No'),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              TextButton(
                child: const Text('Yes'),
                onPressed: () async {
                  // On Web, invalidate caches and force a reload
                  if (kIsWeb) {
                    await invalidateCachesAndReload(context);
                    return;
                  } else {
                    Navigator.of(dialogContext).pop();
                    final uri = Uri.parse(downloadUrl);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    }
                  }
                },
              ),
            ],
          );
        },
      );
    }
  } catch (e, st) {
    logger.e('Error checking for updates', error: e, stackTrace: st);
  }
}
