import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:orbit/storage/storage_data.dart';

// Import/export Orbit configuration data
class OrbitConfigTransfer {
  static const String saveDataExportFileName = 'orbit-save-data.orbit';
  static const String imageDataExportFileName = 'orbit-image-data.orbit';
  static const int exportFormatVersion = 1;
  static const List<int> _magic = <int>[0x4f, 0x52, 0x42, 0x54]; // ORBT
  static const int _containerVersion = 1;
  static const int _kindSaveData = 1;
  static const int _kindImageData = 2;

  static Future<Uint8List> buildSaveDataBytes({
    required StorageData storageData,
  }) async {
    final snapshot = await storageData.exportMainDbSnapshot(
      formatVersion: exportFormatVersion,
    );
    return _encodeSnapshot(snapshot, kind: _kindSaveData, label: 'save data');
  }

  static Future<Uint8List> buildImageDataBytes({
    required StorageData storageData,
  }) async {
    final snapshot = await storageData.exportImageDbSnapshot(
      formatVersion: exportFormatVersion,
    );
    return _encodeSnapshot(snapshot, kind: _kindImageData, label: 'image data');
  }

  static Future<void> importSaveDataBytes({
    required Uint8List bytes,
    required StorageData storageData,
  }) async {
    final snapshot = _decodeSnapshot(
      bytes,
      label: 'save data',
      expectedKind: _kindSaveData,
    );
    await storageData.importMainDbSnapshot(snapshot);
  }

  static Future<void> importImageDataBytes({
    required Uint8List bytes,
    required StorageData storageData,
  }) async {
    final snapshot = _decodeSnapshot(
      bytes,
      label: 'image data',
      expectedKind: _kindImageData,
    );
    await storageData.importImageDbSnapshot(snapshot);
  }

  static Uint8List _encodeSnapshot(
    Map<String, dynamic> snapshot, {
    required int kind,
    required String label,
  }) {
    final jsonBytes = utf8.encode(jsonEncode(snapshot));
    final compressed = GZipEncoder().encodeBytes(jsonBytes);
    if (compressed.isEmpty) {
      throw StateError('Failed to encode $label payload.');
    }

    return Uint8List.fromList(
      <int>[
        ..._magic,
        _containerVersion,
        kind,
        ...compressed,
      ],
    );
  }

  static Map<String, dynamic> _decodeSnapshot(
    Uint8List bytes, {
    required String label,
    required int expectedKind,
  }) {
    if (bytes.length < 7) {
      throw StateError('Selected $label file is empty.');
    }

    if (!_matchesMagic(bytes)) {
      throw StateError('Invalid $label file header.');
    }

    final version = bytes[4];
    if (version != _containerVersion) {
      throw StateError('Unsupported $label format version: $version');
    }

    final kind = bytes[5];
    if (kind != expectedKind) {
      throw StateError('Selected file is not valid for $label import.');
    }

    final compressedBytes = bytes.sublist(6);
    final jsonBytes = GZipDecoder().decodeBytes(compressedBytes);
    final decoded = jsonDecode(utf8.decode(jsonBytes));
    if (decoded is! Map) {
      throw StateError('Invalid $label snapshot format.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  static bool _matchesMagic(Uint8List bytes) {
    for (int i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) {
        return false;
      }
    }
    return true;
  }
}
