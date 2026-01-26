// Storage Data, handles the storage of data to the database
// Used for storing the app's settings and data
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:orbit/data/handlers/channel_graphics_handler.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast_web/sembast_web_interop.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:orbit/ui/preset.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/data/favorite.dart';

class StorageData {
  late Database _mainDb;
  late Database _imageDb;

  final _saveDataStore = stringMapStoreFactory.store('save_data');
  final _graphicsReferenceStore =
      intMapStoreFactory.store('graphics_reference');
  final _graphicsInfoStore = stringMapStoreFactory.store('graphics_info');

  Map<int, ServiceGraphicsReference> serviceGraphicsReferenceMap = {};
  Map<String, ChannelLogoInfo> imageMap = {};

  Future<void> init() async {
    if (kIsWeb || kIsWasm) {
      _mainDb = await databaseFactoryWeb.openDatabase('orbit.db');
    } else {
      final appDir = await getApplicationSupportDirectory();
      final mainDbPath = join(appDir.path, 'orbit.db');
      _mainDb = await databaseFactoryIo.openDatabase(mainDbPath);
    }

    if (kIsWeb || kIsWasm) {
      _imageDb = await databaseFactoryWeb.openDatabase('orbit_data.db');
    } else {
      final appDir = await getApplicationSupportDirectory();
      final imageDbPath = join(appDir.path, 'orbit_data.db');
      _imageDb = await databaseFactoryIo.openDatabase(imageDbPath);
    }

    serviceGraphicsReferenceMap = await getGraphicsListFromStorage();
    imageMap = await getImageListFromStorage();
  }

  Future<void> save(SaveDataType saveDataType, dynamic value) async {
    logger.t('Saving $saveDataType: $value');

    final key = saveDataType.name;
    final Map<String, dynamic> record = {};

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
      case SaveDataType.lastAudioDevice:
      case SaveDataType.audioOutputRoute:
      case SaveDataType.enableAudio:
      case SaveDataType.tuneStart:
      case SaveDataType.sliderSnapping:
      case SaveDataType.showOnAirFavoritesPrompt:
      case SaveDataType.welcomeSeen:
      case SaveDataType.debugMode:
      case SaveDataType.themeMode:
      case SaveDataType.textScale:
      case SaveDataType.logLevel:
      case SaveDataType.linkTraceEnabled:
      case SaveDataType.monitoredDataServices:
      case SaveDataType.secondaryBaudRate:
      case SaveDataType.audioSampleRate:
      case SaveDataType.mediaKeyBehavior:
      case SaveDataType.interfaceScale:
      case SaveDataType.analyticsDisabled:
      case SaveDataType.detectAudioInterruptions:
      case SaveDataType.sxmToken:
        record[key] = value;
        break;
    }

    await _saveDataStore.record(key).put(_mainDb, record);
  }

  Future<dynamic> load(SaveDataType saveDataType,
      {dynamic defaultValue}) async {
    logger.t('Loading $saveDataType');
    final key = saveDataType.name;
    final record =
        await _saveDataStore.record(key).get(_mainDb) as Map<String, dynamic>?;
    if (record == null) return defaultValue;

    switch (saveDataType) {
      case SaveDataType.eq:
        return Int8List.fromList(List<int>.from(record[key]));
      case SaveDataType.presets:
        var presetData = record.values;

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
      case SaveDataType.lastAudioDevice:
      case SaveDataType.audioOutputRoute:
      case SaveDataType.enableAudio:
      case SaveDataType.tuneStart:
      case SaveDataType.sliderSnapping:
      case SaveDataType.showOnAirFavoritesPrompt:
      case SaveDataType.welcomeSeen:
      case SaveDataType.debugMode:
      case SaveDataType.themeMode:
      case SaveDataType.textScale:
      case SaveDataType.logLevel:
      case SaveDataType.linkTraceEnabled:
      case SaveDataType.monitoredDataServices:
      case SaveDataType.secondaryBaudRate:
      case SaveDataType.audioSampleRate:
      case SaveDataType.mediaKeyBehavior:
      case SaveDataType.interfaceScale:
      case SaveDataType.analyticsDisabled:
      case SaveDataType.detectAudioInterruptions:
      case SaveDataType.sxmToken:
        return record[key];
    }
  }

  Future<void> saveImage(ChannelLogoInfo imageGraphic) async {
    logger.d('Saving image: $imageGraphic');
    final key = '${imageGraphic.chanLogoId}-${imageGraphic.seqNum}';
    imageMap[key] = imageGraphic;

    final record = <String, dynamic>{
      'referenceId': imageGraphic.chanLogoId,
      'sequence': imageGraphic.seqNum,
      'imageData': imageGraphic.imageData,
    };
    final db = _imageDb;
    await _graphicsInfoStore.record(key).put(db, record);
  }

  Future<void> saveGraphicsList(
      List<ServiceGraphicsReference> graphicsList) async {
    logger.d('Saving graphics list of size: ${graphicsList.length}');
    final db = _imageDb;
    await db.transaction((transaction) async {
      for (var graphicsReference in graphicsList) {
        serviceGraphicsReferenceMap[graphicsReference.sid] = graphicsReference;
        final record = <String, dynamic>{
          'sid': graphicsReference.sid,
          'referenceId': graphicsReference.referenceId,
          'sequence': graphicsReference.sequence,
        };
        await _graphicsReferenceStore
            .record(graphicsReference.sid)
            .put(transaction, record);
      }
    });
  }

  Future<Map<int, ServiceGraphicsReference>>
      getGraphicsListFromStorage() async {
    final records = await _graphicsReferenceStore.find(_imageDb);
    final Map<int, ServiceGraphicsReference> map = {};
    for (var record in records) {
      final data = record.value;
      final ref = ServiceGraphicsReference(
        sid: data['sid'] as int,
        referenceId: data['referenceId'] as int,
        sequence: data['sequence'] as int,
      );
      map[ref.sid] = ref;
    }
    return map;
  }

  Future<Map<String, ChannelLogoInfo>> getImageListFromStorage() async {
    final records = await _graphicsInfoStore.find(_imageDb);
    final Map<String, ChannelLogoInfo> map = {};
    for (var record in records) {
      final data = record.value;
      final key = '${data['referenceId']}-${data['sequence']}';
      final info = ChannelLogoInfo(
        chanLogoId: data['referenceId'] as int,
        seqNum: data['sequence'] as int,
        imageData: List<int>.from(data['imageData'] as List),
      );
      map[key] = info;
    }
    return map;
  }

  List<int> getImageForSid(int sid) {
    // Key format: "{referenceId}-{sequence}"
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
    // Clear main app data
    await _saveDataStore.delete(_mainDb);

    // Clear image/graphics data from image DB
    await _graphicsReferenceStore.delete(_imageDb);
    await _graphicsInfoStore.delete(_imageDb);
  }

  Future<void> delete(SaveDataType saveDataType) async {
    final key = saveDataType.name;
    await _saveDataStore.record(key).delete(_mainDb);
  }

  Future<void> deleteImageData() async {
    await _graphicsReferenceStore.delete(_imageDb);
    await _graphicsInfoStore.delete(_imageDb);
  }
}

enum SaveDataType {
  eq,
  presets,
  favorites,
  lastSid,
  lastPort,
  lastAudioDevice,
  audioOutputRoute,
  enableAudio,
  tuneStart,
  sliderSnapping,
  showOnAirFavoritesPrompt,
  welcomeSeen,
  debugMode,
  themeMode,
  textScale,
  logLevel,
  linkTraceEnabled,
  monitoredDataServices,
  secondaryBaudRate,
  audioSampleRate,
  mediaKeyBehavior,
  interfaceScale,
  analyticsDisabled,
  detectAudioInterruptions,
  sxmToken
}
