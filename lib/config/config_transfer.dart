import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:orbit/storage/storage_data.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:universal_io/io.dart';

// Import/export Orbit config as a zip
class OrbitConfigTransfer {
  static const String mainDbName = 'orbit.db';
  static const String imageDbName = 'orbit_data.db';
  static const int exportFormatVersion = 1;

  static Future<Uint8List> buildZipBytes({
    required StorageData storageData,
  }) async {
    // Snapshot both DBs via sembast APIs
    final mainSnapshot = await storageData.exportMainDbSnapshot(
      formatVersion: exportFormatVersion,
    );
    final imageSnapshot = await storageData.exportImageDbSnapshot(
      formatVersion: exportFormatVersion,
    );

    final archive = Archive();
    final mainJson = jsonEncode(mainSnapshot);
    final imageJson = jsonEncode(imageSnapshot);

    archive.addFile(ArchiveFile(
      mainDbName,
      mainJson.length,
      utf8.encode(mainJson),
    ));

    archive.addFile(ArchiveFile(
      imageDbName,
      imageJson.length,
      utf8.encode(imageJson),
    ));

    final zipBytes = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipBytes);
  }

  static Future<void> importFromZipBytes({
    required Uint8List zipBytes,
    required StorageData storageData,
  }) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    Map<String, Map<String, dynamic>> snapshots = {};

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.split('/').last;
      if (name != mainDbName && name != imageDbName) continue;

      final content = file.content as List<int>;
      final text = utf8.decode(content);
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw StateError('Invalid snapshot format in $name');
      }
      snapshots[name] = Map<String, dynamic>.from(decoded);
    }

    if (snapshots.isEmpty) {
      throw StateError(
          'Zip does not contain $mainDbName or $imageDbName snapshots!');
    }

    // Overwrite records in-place in IndexedDB
    if (kIsWeb || kIsWasm) {
      if (snapshots.containsKey(mainDbName)) {
        await storageData.importMainDbSnapshot(
          Map<String, dynamic>.from(snapshots[mainDbName]!),
        );
      }

      if (snapshots.containsKey(imageDbName)) {
        await storageData.importImageDbSnapshot(
          Map<String, dynamic>.from(snapshots[imageDbName]!),
        );
      }

      return;
    }

    final appDir = await getApplicationSupportDirectory();
    final mainPath = p.join(appDir.path, mainDbName);
    final imagePath = p.join(appDir.path, imageDbName);

    await storageData.close();

    if (snapshots.containsKey(mainDbName)) {
      await _backupDbFile(mainPath);
    }
    if (snapshots.containsKey(imageDbName)) {
      await _backupDbFile(imagePath);
    }

    // Re-open will create any missing DB files
    await storageData.init();

    // Import whichever DB snapshots were provided
    if (snapshots.containsKey(mainDbName)) {
      await storageData.importMainDbSnapshot(
        Map<String, dynamic>.from(snapshots[mainDbName]!),
      );
    }

    if (snapshots.containsKey(imageDbName)) {
      await storageData.importImageDbSnapshot(
        Map<String, dynamic>.from(snapshots[imageDbName]!),
      );
    }
  }

  static Future<void> _backupDbFile(String path) async {
    final dbFile = File(path);
    if (!await dbFile.exists()) return;

    final backupPath = '$path.old';
    final backupFile = File(backupPath);
    if (await backupFile.exists()) {
      final ts = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      await backupFile.rename('$backupPath.$ts');
    }
    await dbFile.rename(backupPath);
  }
}
