import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'orbit_database.g.dart';

class SaveDataEntries extends Table {
  TextColumn get key => text()();
  TextColumn get valueJson => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

class GraphicsReferences extends Table {
  IntColumn get sid => integer()();
  IntColumn get referenceId => integer()();
  IntColumn get sequence => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{sid};
}

class GraphicsInfos extends Table {
  TextColumn get key => text()();
  IntColumn get referenceId => integer()();
  IntColumn get sequence => integer()();
  BlobColumn get imageData => blob()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{key};
}

@DriftDatabase(
  tables: <Type>[
    SaveDataEntries,
    GraphicsReferences,
    GraphicsInfos,
  ],
)
class OrbitDatabase extends _$OrbitDatabase {
  OrbitDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  Future<void> runInTransaction(Future<void> Function() action) {
    return transaction(action);
  }

  Future<void> upsertSaveDataEntry(String key, String valueJson) async {
    await into(saveDataEntries).insertOnConflictUpdate(
      SaveDataEntriesCompanion.insert(
        key: key,
        valueJson: valueJson,
      ),
    );
  }

  Future<SaveDataEntry?> getSaveDataEntry(String key) {
    return (select(saveDataEntries)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
  }

  Future<List<SaveDataEntry>> getAllSaveDataEntries() {
    return select(saveDataEntries).get();
  }

  Future<void> clearSaveDataEntries() async {
    await delete(saveDataEntries).go();
  }

  Future<void> deleteSaveDataEntry(String key) async {
    await (delete(saveDataEntries)..where((t) => t.key.equals(key))).go();
  }

  Future<void> upsertGraphicsReference(
    int sid,
    int referenceId,
    int sequence,
  ) async {
    await into(graphicsReferences).insertOnConflictUpdate(
      GraphicsReferencesCompanion(
        sid: Value<int>(sid),
        referenceId: Value<int>(referenceId),
        sequence: Value<int>(sequence),
      ),
    );
  }

  Future<List<GraphicsReference>> getGraphicsReferences() {
    return select(graphicsReferences).get();
  }

  Future<void> clearGraphicsReferences() async {
    await delete(graphicsReferences).go();
  }

  Future<void> upsertGraphicsInfo(
    String key,
    int referenceId,
    int sequence,
    Uint8List imageData,
  ) async {
    await into(graphicsInfos).insertOnConflictUpdate(
      GraphicsInfosCompanion.insert(
        key: key,
        referenceId: referenceId,
        sequence: sequence,
        imageData: imageData,
      ),
    );
  }

  Future<List<GraphicsInfo>> getGraphicsInfos() {
    return select(graphicsInfos).get();
  }

  Future<void> clearGraphicsInfos() async {
    await delete(graphicsInfos).go();
  }
}

QueryExecutor _openConnection() {
  return driftDatabase(
    name: 'orbit_drift',
    native: DriftNativeOptions(
      databaseDirectory: getApplicationSupportDirectory,
    ),
  );
}
