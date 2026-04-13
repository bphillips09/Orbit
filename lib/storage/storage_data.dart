// Storage Data, handles the storage of data to the database
// Used for storing the app's settings and data
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:orbit/data/favorite.dart';
import 'package:orbit/data/handlers/channel_graphics_handler.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/storage/orbit_database.dart';
import 'package:orbit/storage/sembast_factory.dart';
import 'package:orbit/ui/preset.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:universal_io/io.dart';

class StorageData {
  static const String _legacyMainDbName = 'orbit.db';
  static const String _legacyImageDbName = 'orbit_data.db';
  static const String _driftMigrationMarkerKey = '__drift_migration_v1';

  late OrbitDatabase _db;
  bool _initialized = false;

  Map<int, ServiceGraphicsReference> serviceGraphicsReferenceMap = {};
  Map<String, ChannelLogoInfo> imageMap = {};

  Future<void> init() async {
    logger.d('StorageData init started');
    _db = OrbitDatabase();
    await _checkForSembastMigration();
    serviceGraphicsReferenceMap = await getGraphicsListFromStorage();
    imageMap = await getImageListFromStorage();
    _initialized = true;
    logger.d(
      'StorageData init complete (graphicsRefs: ${serviceGraphicsReferenceMap.length}, images: ${imageMap.length})',
    );
  }

  Future<void> close() async {
    if (!_initialized) return;
    try {
      await _db.close();
    } catch (_) {}
    _initialized = false;
  }

  Future<Map<String, dynamic>> exportMainDbSnapshot({
    required int formatVersion,
  }) async {
    logger.t('Exporting main storage snapshot');
    final rows = await _db.getAllSaveDataEntries();
    final records = <Map<String, dynamic>>[];
    for (final row in rows) {
      if (row.key.startsWith('__')) {
        continue;
      }
      records.add(<String, dynamic>{
        'key': row.key,
        'value': _decodeJsonValue(row.valueJson),
      });
    }

    final snapshot = <String, dynamic>{
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'stores': <String, dynamic>{
        'save_data': records,
      },
    };
    logger.d('Exported main storage snapshot (records: ${records.length})');
    return snapshot;
  }

  Future<Map<String, dynamic>> exportImageDbSnapshot({
    required int formatVersion,
  }) async {
    logger.t('Exporting image storage snapshot');
    final references = await _db.getGraphicsReferences();
    final infos = await _db.getGraphicsInfos();

    final snapshot = <String, dynamic>{
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'stores': <String, dynamic>{
        'graphics_reference': references
            .map((row) => <String, dynamic>{
                  'key': row.sid,
                  'value': <String, dynamic>{
                    'sid': row.sid,
                    'referenceId': row.referenceId,
                    'sequence': row.sequence,
                  },
                })
            .toList(),
        'graphics_info': infos
            .map((row) => <String, dynamic>{
                  'key': row.key,
                  'value': <String, dynamic>{
                    'referenceId': row.referenceId,
                    'sequence': row.sequence,
                    'imageData': row.imageData.toList(),
                  },
                })
            .toList(),
      },
    };
    logger.d(
      'Exported image storage snapshot (references: ${references.length}, images: ${infos.length})',
    );
    return snapshot;
  }

  Future<void> importMainDbSnapshot(Map<String, dynamic> snapshot) async {
    final storesRaw = snapshot['stores'];
    if (storesRaw is! Map) {
      throw StateError('Snapshot is missing "stores" map');
    }

    final stores = Map<String, dynamic>.from(storesRaw);
    final recordsRaw = stores['save_data'];
    final records = recordsRaw is List ? recordsRaw : const <dynamic>[];
    logger.d('Importing main storage snapshot (records: ${records.length})');

    await _db.runInTransaction(() async {
      await _db.clearSaveDataEntries();
      for (final record in records) {
        if (record is! Map) continue;
        final map = Map<String, dynamic>.from(record);
        final dynamic keyRaw = map['key'];
        if (keyRaw is! String || keyRaw.isEmpty) continue;
        await _putSaveDataRecord(keyRaw, map['value']);
      }
    });

    await _setMigrationMarker();
    logger.d('Imported main storage snapshot');
  }

  Future<void> importImageDbSnapshot(Map<String, dynamic> snapshot) async {
    final storesRaw = snapshot['stores'];
    if (storesRaw is! Map) {
      throw StateError('Snapshot is missing "stores" map');
    }

    final stores = Map<String, dynamic>.from(storesRaw);
    final referencesRaw = stores['graphics_reference'];
    final infosRaw = stores['graphics_info'];
    final references =
        referencesRaw is List ? referencesRaw : const <dynamic>[];
    final infos = infosRaw is List ? infosRaw : const <dynamic>[];
    logger.d(
      'Importing image storage snapshot (references: ${references.length}, images: ${infos.length})',
    );

    await _db.runInTransaction(() async {
      await _db.clearGraphicsReferences();
      await _db.clearGraphicsInfos();

      for (final record in references) {
        if (record is! Map) continue;
        final map = Map<String, dynamic>.from(record);
        final dynamic valueRaw = map['value'];
        if (valueRaw is! Map) continue;
        final value = Map<String, dynamic>.from(valueRaw);
        final sid = _asInt(value['sid']);
        final referenceId = _asInt(value['referenceId']);
        final sequence = _asInt(value['sequence']);
        if (sid == null || referenceId == null || sequence == null) continue;
        await _db.upsertGraphicsReference(sid, referenceId, sequence);
      }

      for (final record in infos) {
        if (record is! Map) continue;
        final map = Map<String, dynamic>.from(record);
        final dynamic keyRaw = map['key'];
        final dynamic valueRaw = map['value'];
        if (keyRaw is! String || valueRaw is! Map) continue;
        final value = Map<String, dynamic>.from(valueRaw);
        final referenceId = _asInt(value['referenceId']);
        final sequence = _asInt(value['sequence']);
        final imageData = _asByteList(value['imageData']);
        if (referenceId == null || sequence == null || imageData == null) {
          continue;
        }
        await _db.upsertGraphicsInfo(
          keyRaw,
          referenceId,
          sequence,
          Uint8List.fromList(imageData),
        );
      }
    });

    serviceGraphicsReferenceMap = await getGraphicsListFromStorage();
    imageMap = await getImageListFromStorage();
    logger.d(
      'Imported image storage snapshot (graphicsRefs: ${serviceGraphicsReferenceMap.length}, images: ${imageMap.length})',
    );
  }

  Future<void> save(SaveDataType saveDataType, dynamic value) async {
    try {
      logger.t('Saving $saveDataType: $value');

      final key = saveDataType.name;
      final record = <String, dynamic>{};

      switch (saveDataType) {
        case SaveDataType.eq:
          record[key] = value.toList();
          break;
        case SaveDataType.presets:
          if (value is List<Preset>) {
            for (int i = 0; i < value.length; i++) {
              record[i.toString()] = {
                'sid': value[i].sid,
                'channelNumber': value[i].channelNumber,
                'channelName': value[i].channelName,
              };
            }
          }
          break;
        case SaveDataType.favorites:
          if (value is List<Favorite>) {
            record[key] = value.map((f) => f.toMap()).toList();
          } else {
            record[key] = [];
          }
          break;
        case SaveDataType.lastSid:
        case SaveDataType.lastPort:
        case SaveDataType.lastPortTransport:
        case SaveDataType.preferredDeviceProtocol:
        case SaveDataType.lastAudioDevice:
        case SaveDataType.audioOutputRoute:
        case SaveDataType.enableAudio:
        case SaveDataType.tuneStart:
        case SaveDataType.sliderSnapping:
        case SaveDataType.showOnAirFavoritesPrompt:
        case SaveDataType.playFavoritesNotification:
        case SaveDataType.welcomeSeen:
        case SaveDataType.debugMode:
        case SaveDataType.themeMode:
        case SaveDataType.textScale:
        case SaveDataType.logLevel:
        case SaveDataType.linkTraceEnabled:
        case SaveDataType.logOverlayEnabled:
        case SaveDataType.monitoredDSI:
        case SaveDataType.secondaryBaudRate:
        case SaveDataType.audioSampleRate:
        case SaveDataType.mediaKeyBehavior:
        case SaveDataType.mediaKeysTrackDuringScanMix:
        case SaveDataType.mediaKeysNavigateFavoritesAndGuide:
        case SaveDataType.reverseMediaForwardBack:
        case SaveDataType.presetArrowVisibility:
        case SaveDataType.dismissGuideOnSelect:
        case SaveDataType.dismissOnAirFavoritesOnSelect:
        case SaveDataType.interfaceScale:
        case SaveDataType.analyticsDisabled:
        case SaveDataType.detectAudioInterruptions:
        case SaveDataType.sxmToken:
        case SaveDataType.useNativeAuxInput:
        case SaveDataType.quitAuxWhenSuspended:
        case SaveDataType.switchToAuxOnFocusGain:
        case SaveDataType.autoConnectOnFocusGain:
        case SaveDataType.connectionRetryCount:
        case SaveDataType.playStartupSilence:
        case SaveDataType.smallScreenMode:
        case SaveDataType.safeAreaInsetScale:
        case SaveDataType.androidImmersiveMode:
          record[key] = value;
          break;
      }

      await _putSaveDataRecord(key, record);
    } catch (e, st) {
      logger.w(
        'Storage save failed for $saveDataType: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<dynamic> load(
    SaveDataType saveDataType, {
    dynamic defaultValue,
  }) async {
    try {
      logger.t('Loading $saveDataType');
      final key = saveDataType.name;
      final record = await _getSaveDataRecord(key);
      if (record == null) return defaultValue;

      switch (saveDataType) {
        case SaveDataType.eq:
          return Int8List.fromList(List<int>.from(record[key]));
        case SaveDataType.presets:
          final presetData = record.values;
          return presetData
              .map((data) => Preset(
                    sid: data['sid'] as int,
                    channelNumber: data['channelNumber'] as int,
                    channelName: data['channelName'] as String,
                  ))
              .toList();
        case SaveDataType.favorites:
          final List<dynamic> list = (record[key] as List?) ?? const [];
          return list
              .map((e) => Favorite.fromMap(Map<String, dynamic>.from(e)))
              .toList();
        case SaveDataType.lastSid:
        case SaveDataType.lastPort:
        case SaveDataType.lastPortTransport:
        case SaveDataType.preferredDeviceProtocol:
        case SaveDataType.lastAudioDevice:
        case SaveDataType.audioOutputRoute:
        case SaveDataType.enableAudio:
        case SaveDataType.tuneStart:
        case SaveDataType.sliderSnapping:
        case SaveDataType.showOnAirFavoritesPrompt:
        case SaveDataType.playFavoritesNotification:
        case SaveDataType.welcomeSeen:
        case SaveDataType.debugMode:
        case SaveDataType.themeMode:
        case SaveDataType.textScale:
        case SaveDataType.logLevel:
        case SaveDataType.linkTraceEnabled:
        case SaveDataType.logOverlayEnabled:
        case SaveDataType.monitoredDSI:
        case SaveDataType.secondaryBaudRate:
        case SaveDataType.audioSampleRate:
        case SaveDataType.mediaKeyBehavior:
        case SaveDataType.mediaKeysTrackDuringScanMix:
        case SaveDataType.mediaKeysNavigateFavoritesAndGuide:
        case SaveDataType.reverseMediaForwardBack:
        case SaveDataType.presetArrowVisibility:
        case SaveDataType.dismissGuideOnSelect:
        case SaveDataType.dismissOnAirFavoritesOnSelect:
        case SaveDataType.interfaceScale:
        case SaveDataType.analyticsDisabled:
        case SaveDataType.detectAudioInterruptions:
        case SaveDataType.sxmToken:
        case SaveDataType.useNativeAuxInput:
        case SaveDataType.quitAuxWhenSuspended:
        case SaveDataType.switchToAuxOnFocusGain:
        case SaveDataType.autoConnectOnFocusGain:
        case SaveDataType.connectionRetryCount:
        case SaveDataType.playStartupSilence:
        case SaveDataType.smallScreenMode:
        case SaveDataType.safeAreaInsetScale:
        case SaveDataType.androidImmersiveMode:
          return record[key];
      }
    } catch (e, st) {
      logger.w(
        'Storage load failed for $saveDataType: $e',
        error: e,
        stackTrace: st,
      );
      return defaultValue;
    }
  }

  Future<void> saveImage(ChannelLogoInfo imageGraphic) async {
    logger.d('Saving image: $imageGraphic');
    final key = '${imageGraphic.chanLogoId}-${imageGraphic.seqNum}';
    imageMap[key] = imageGraphic;

    await _db.upsertGraphicsInfo(
      key,
      imageGraphic.chanLogoId,
      imageGraphic.seqNum,
      Uint8List.fromList(imageGraphic.imageData),
    );
  }

  Future<void> saveGraphicsList(
    List<ServiceGraphicsReference> graphicsList,
  ) async {
    logger.d('Saving graphics list of size: ${graphicsList.length}');
    await _db.runInTransaction(() async {
      for (final graphicsReference in graphicsList) {
        serviceGraphicsReferenceMap[graphicsReference.sid] = graphicsReference;
        await _db.upsertGraphicsReference(
          graphicsReference.sid,
          graphicsReference.referenceId,
          graphicsReference.sequence,
        );
      }
    });
  }

  Future<Map<int, ServiceGraphicsReference>>
      getGraphicsListFromStorage() async {
    final rows = await _db.getGraphicsReferences();
    final map = <int, ServiceGraphicsReference>{};
    for (final row in rows) {
      final ref = ServiceGraphicsReference(
        sid: row.sid,
        referenceId: row.referenceId,
        sequence: row.sequence,
      );
      map[ref.sid] = ref;
    }
    return map;
  }

  Future<Map<String, ChannelLogoInfo>> getImageListFromStorage() async {
    final rows = await _db.getGraphicsInfos();
    final map = <String, ChannelLogoInfo>{};
    for (final row in rows) {
      map[row.key] = ChannelLogoInfo(
        chanLogoId: row.referenceId,
        seqNum: row.sequence,
        imageData: row.imageData.toList(),
      );
    }
    return map;
  }

  List<int> getImageForSid(int sid) {
    final serviceGraphicsRef = serviceGraphicsReferenceMap[sid];
    if (serviceGraphicsRef == null) return List.empty();

    final key =
        '${serviceGraphicsRef.referenceId}-${serviceGraphicsRef.sequence}';
    final imageInfo = imageMap[key];
    if (imageInfo == null) return List.empty();

    if (imageInfo.seqNum == serviceGraphicsRef.sequence) {
      return imageInfo.imageData;
    }
    return List.empty();
  }

  Future<void> deleteAll() async {
    try {
      await _db.runInTransaction(() async {
        await _db.clearSaveDataEntries();
        await _db.clearGraphicsReferences();
        await _db.clearGraphicsInfos();
      });
      serviceGraphicsReferenceMap.clear();
      imageMap.clear();
      await _setMigrationMarker();
    } catch (e, st) {
      logger.w('Storage deleteAll failed: $e', error: e, stackTrace: st);
    }
  }

  Future<void> delete(SaveDataType saveDataType) async {
    try {
      await _db.deleteSaveDataEntry(saveDataType.name);
    } catch (e, st) {
      logger.w(
        'Storage delete failed for $saveDataType: $e',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<void> deleteImageData() async {
    try {
      await _db.clearGraphicsReferences();
      await _db.clearGraphicsInfos();
      serviceGraphicsReferenceMap.clear();
      imageMap.clear();
    } catch (e, st) {
      logger.w('Storage deleteImageData failed: $e', error: e, stackTrace: st);
    }
  }

  Future<void> _checkForSembastMigration() async {
    final marker = await _getSaveDataRecord(_driftMigrationMarkerKey);
    if (marker != null) {
      logger.d('Legacy sembast migration already completed, skipping');
      return;
    }
    logger.d('Legacy sembast migration started');

    Map<String, dynamic>? mainSnapshot;
    Map<String, dynamic>? imageSnapshot;

    Database? mainDb;
    Database? imageDb;
    try {
      mainDb = await _openLegacyDbIfExists(_legacyMainDbName);
      if (mainDb != null) {
        logger.d('Legacy main DB found, exporting snapshot');
        mainSnapshot = await _exportLegacyDbSnapshot(
          mainDb,
          storeNames: const <String>['save_data'],
        );
      }
    } catch (e, st) {
      logger.w(
        'Legacy main DB migration read failed: $e',
        error: e,
        stackTrace: st,
      );
    } finally {
      if (mainDb != null) {
        try {
          await mainDb.close();
        } catch (_) {}
      }
    }

    try {
      imageDb = await _openLegacyDbIfExists(_legacyImageDbName);
      if (imageDb != null) {
        logger.d('Legacy image DB found, exporting snapshot');
        imageSnapshot = await _exportLegacyDbSnapshot(
          imageDb,
          storeNames: const <String>['graphics_reference', 'graphics_info'],
        );
      }
    } catch (e, st) {
      logger.w(
        'Legacy image DB migration read failed: $e',
        error: e,
        stackTrace: st,
      );
    } finally {
      if (imageDb != null) {
        try {
          await imageDb.close();
        } catch (_) {}
      }
    }

    if (mainSnapshot != null) {
      logger.d(
        'Applying migrated main snapshot (records: ${_snapshotStoreRecordCount(mainSnapshot, 'save_data')})',
      );
      await importMainDbSnapshot(mainSnapshot);
    }
    if (imageSnapshot != null) {
      logger.d(
        'Applying migrated image snapshot (references: ${_snapshotStoreRecordCount(imageSnapshot, 'graphics_reference')}, images: ${_snapshotStoreRecordCount(imageSnapshot, 'graphics_info')})',
      );
      await importImageDbSnapshot(imageSnapshot);
    }

    await _setMigrationMarker();
    logger.d('Legacy sembast migration completed');
  }

  Future<Database?> _openLegacyDbIfExists(String dbName) async {
    if (kIsWeb || kIsWasm) {
      logger.t('Opening legacy web DB: $dbName');
      return databaseFactoryPlatform.openDatabase(dbName);
    }

    final appDir = await getApplicationSupportDirectory();
    final dbPath = join(appDir.path, dbName);
    final dbFile = File(dbPath);
    if (!await dbFile.exists()) {
      logger.t('Legacy DB not found, skipping: $dbName');
      return null;
    }
    logger.t('Opening legacy DB from file: $dbPath');
    return databaseFactoryPlatform.openDatabase(dbPath);
  }

  Future<Map<String, dynamic>> _exportLegacyDbSnapshot(
    Database db, {
    required List<String> storeNames,
  }) async {
    final storesOut = <String, dynamic>{};

    for (final storeName in storeNames) {
      final store = StoreRef<dynamic, dynamic>(storeName);
      final records = await store.find(db);
      storesOut[storeName] = records
          .map((r) => <String, dynamic>{'key': r.key, 'value': r.value})
          .toList();
    }

    return <String, dynamic>{
      'formatVersion': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'stores': storesOut,
    };
  }

  Future<void> _putSaveDataRecord(String key, dynamic value) async {
    await _db.upsertSaveDataEntry(key, jsonEncode(value));
  }

  Future<Map<String, dynamic>?> _getSaveDataRecord(String key) async {
    final row = await _db.getSaveDataEntry(key);
    if (row == null) return null;
    final decoded = _decodeJsonValue(row.valueJson);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return null;
  }

  Future<void> _setMigrationMarker() async {
    await _putSaveDataRecord(
      _driftMigrationMarkerKey,
      <String, dynamic>{'migrated': true},
    );
    logger.t('Storage migration marker updated');
  }

  dynamic _decodeJsonValue(String valueJson) {
    try {
      return jsonDecode(valueJson);
    } catch (_) {
      return null;
    }
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  List<int>? _asByteList(dynamic value) {
    if (value is Uint8List) return value.toList();
    if (value is List<int>) return value;
    if (value is List) {
      return value.map((e) => _asInt(e) ?? 0).toList();
    }
    return null;
  }

  int _snapshotStoreRecordCount(
      Map<String, dynamic> snapshot, String storeName) {
    final storesRaw = snapshot['stores'];
    if (storesRaw is! Map) return 0;
    final stores = Map<String, dynamic>.from(storesRaw);
    final records = stores[storeName];
    return records is List ? records.length : 0;
  }
}

enum SaveDataType {
  eq,
  presets,
  favorites,
  lastSid,
  lastPort,
  lastPortTransport,
  preferredDeviceProtocol,
  lastAudioDevice,
  audioOutputRoute,
  enableAudio,
  tuneStart,
  sliderSnapping,
  showOnAirFavoritesPrompt,
  playFavoritesNotification,
  welcomeSeen,
  debugMode,
  themeMode,
  textScale,
  logLevel,
  linkTraceEnabled,
  logOverlayEnabled,
  monitoredDSI,
  secondaryBaudRate,
  audioSampleRate,
  mediaKeyBehavior,
  mediaKeysTrackDuringScanMix,
  mediaKeysNavigateFavoritesAndGuide,
  reverseMediaForwardBack,
  presetArrowVisibility,
  dismissGuideOnSelect,
  dismissOnAirFavoritesOnSelect,
  interfaceScale,
  analyticsDisabled,
  detectAudioInterruptions,
  sxmToken,
  useNativeAuxInput,
  quitAuxWhenSuspended,
  switchToAuxOnFocusGain,
  autoConnectOnFocusGain,
  connectionRetryCount,
  playStartupSilence,
  smallScreenMode,
  safeAreaInsetScale,
  androidImmersiveMode,
}
