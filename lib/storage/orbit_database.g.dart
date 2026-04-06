// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'orbit_database.dart';

// ignore_for_file: type=lint
class $SaveDataEntriesTable extends SaveDataEntries
    with TableInfo<$SaveDataEntriesTable, SaveDataEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SaveDataEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _valueJsonMeta =
      const VerificationMeta('valueJson');
  @override
  late final GeneratedColumn<String> valueJson = GeneratedColumn<String>(
      'value_json', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, valueJson];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'save_data_entries';
  @override
  VerificationContext validateIntegrity(Insertable<SaveDataEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value_json')) {
      context.handle(_valueJsonMeta,
          valueJson.isAcceptableOrUnknown(data['value_json']!, _valueJsonMeta));
    } else if (isInserting) {
      context.missing(_valueJsonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SaveDataEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SaveDataEntry(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      valueJson: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}value_json'])!,
    );
  }

  @override
  $SaveDataEntriesTable createAlias(String alias) {
    return $SaveDataEntriesTable(attachedDatabase, alias);
  }
}

class SaveDataEntry extends DataClass implements Insertable<SaveDataEntry> {
  final String key;
  final String valueJson;
  const SaveDataEntry({required this.key, required this.valueJson});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value_json'] = Variable<String>(valueJson);
    return map;
  }

  SaveDataEntriesCompanion toCompanion(bool nullToAbsent) {
    return SaveDataEntriesCompanion(
      key: Value(key),
      valueJson: Value(valueJson),
    );
  }

  factory SaveDataEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SaveDataEntry(
      key: serializer.fromJson<String>(json['key']),
      valueJson: serializer.fromJson<String>(json['valueJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'valueJson': serializer.toJson<String>(valueJson),
    };
  }

  SaveDataEntry copyWith({String? key, String? valueJson}) => SaveDataEntry(
        key: key ?? this.key,
        valueJson: valueJson ?? this.valueJson,
      );
  SaveDataEntry copyWithCompanion(SaveDataEntriesCompanion data) {
    return SaveDataEntry(
      key: data.key.present ? data.key.value : this.key,
      valueJson: data.valueJson.present ? data.valueJson.value : this.valueJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SaveDataEntry(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, valueJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SaveDataEntry &&
          other.key == this.key &&
          other.valueJson == this.valueJson);
}

class SaveDataEntriesCompanion extends UpdateCompanion<SaveDataEntry> {
  final Value<String> key;
  final Value<String> valueJson;
  final Value<int> rowid;
  const SaveDataEntriesCompanion({
    this.key = const Value.absent(),
    this.valueJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SaveDataEntriesCompanion.insert({
    required String key,
    required String valueJson,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        valueJson = Value(valueJson);
  static Insertable<SaveDataEntry> custom({
    Expression<String>? key,
    Expression<String>? valueJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (valueJson != null) 'value_json': valueJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SaveDataEntriesCompanion copyWith(
      {Value<String>? key, Value<String>? valueJson, Value<int>? rowid}) {
    return SaveDataEntriesCompanion(
      key: key ?? this.key,
      valueJson: valueJson ?? this.valueJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (valueJson.present) {
      map['value_json'] = Variable<String>(valueJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SaveDataEntriesCompanion(')
          ..write('key: $key, ')
          ..write('valueJson: $valueJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GraphicsReferencesTable extends GraphicsReferences
    with TableInfo<$GraphicsReferencesTable, GraphicsReference> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GraphicsReferencesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sidMeta = const VerificationMeta('sid');
  @override
  late final GeneratedColumn<int> sid = GeneratedColumn<int>(
      'sid', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _referenceIdMeta =
      const VerificationMeta('referenceId');
  @override
  late final GeneratedColumn<int> referenceId = GeneratedColumn<int>(
      'reference_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _sequenceMeta =
      const VerificationMeta('sequence');
  @override
  late final GeneratedColumn<int> sequence = GeneratedColumn<int>(
      'sequence', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [sid, referenceId, sequence];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'graphics_references';
  @override
  VerificationContext validateIntegrity(Insertable<GraphicsReference> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('sid')) {
      context.handle(
          _sidMeta, sid.isAcceptableOrUnknown(data['sid']!, _sidMeta));
    }
    if (data.containsKey('reference_id')) {
      context.handle(
          _referenceIdMeta,
          referenceId.isAcceptableOrUnknown(
              data['reference_id']!, _referenceIdMeta));
    } else if (isInserting) {
      context.missing(_referenceIdMeta);
    }
    if (data.containsKey('sequence')) {
      context.handle(_sequenceMeta,
          sequence.isAcceptableOrUnknown(data['sequence']!, _sequenceMeta));
    } else if (isInserting) {
      context.missing(_sequenceMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sid};
  @override
  GraphicsReference map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GraphicsReference(
      sid: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sid'])!,
      referenceId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}reference_id'])!,
      sequence: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sequence'])!,
    );
  }

  @override
  $GraphicsReferencesTable createAlias(String alias) {
    return $GraphicsReferencesTable(attachedDatabase, alias);
  }
}

class GraphicsReference extends DataClass
    implements Insertable<GraphicsReference> {
  final int sid;
  final int referenceId;
  final int sequence;
  const GraphicsReference(
      {required this.sid, required this.referenceId, required this.sequence});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['sid'] = Variable<int>(sid);
    map['reference_id'] = Variable<int>(referenceId);
    map['sequence'] = Variable<int>(sequence);
    return map;
  }

  GraphicsReferencesCompanion toCompanion(bool nullToAbsent) {
    return GraphicsReferencesCompanion(
      sid: Value(sid),
      referenceId: Value(referenceId),
      sequence: Value(sequence),
    );
  }

  factory GraphicsReference.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GraphicsReference(
      sid: serializer.fromJson<int>(json['sid']),
      referenceId: serializer.fromJson<int>(json['referenceId']),
      sequence: serializer.fromJson<int>(json['sequence']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sid': serializer.toJson<int>(sid),
      'referenceId': serializer.toJson<int>(referenceId),
      'sequence': serializer.toJson<int>(sequence),
    };
  }

  GraphicsReference copyWith({int? sid, int? referenceId, int? sequence}) =>
      GraphicsReference(
        sid: sid ?? this.sid,
        referenceId: referenceId ?? this.referenceId,
        sequence: sequence ?? this.sequence,
      );
  GraphicsReference copyWithCompanion(GraphicsReferencesCompanion data) {
    return GraphicsReference(
      sid: data.sid.present ? data.sid.value : this.sid,
      referenceId:
          data.referenceId.present ? data.referenceId.value : this.referenceId,
      sequence: data.sequence.present ? data.sequence.value : this.sequence,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GraphicsReference(')
          ..write('sid: $sid, ')
          ..write('referenceId: $referenceId, ')
          ..write('sequence: $sequence')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(sid, referenceId, sequence);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GraphicsReference &&
          other.sid == this.sid &&
          other.referenceId == this.referenceId &&
          other.sequence == this.sequence);
}

class GraphicsReferencesCompanion extends UpdateCompanion<GraphicsReference> {
  final Value<int> sid;
  final Value<int> referenceId;
  final Value<int> sequence;
  const GraphicsReferencesCompanion({
    this.sid = const Value.absent(),
    this.referenceId = const Value.absent(),
    this.sequence = const Value.absent(),
  });
  GraphicsReferencesCompanion.insert({
    this.sid = const Value.absent(),
    required int referenceId,
    required int sequence,
  })  : referenceId = Value(referenceId),
        sequence = Value(sequence);
  static Insertable<GraphicsReference> custom({
    Expression<int>? sid,
    Expression<int>? referenceId,
    Expression<int>? sequence,
  }) {
    return RawValuesInsertable({
      if (sid != null) 'sid': sid,
      if (referenceId != null) 'reference_id': referenceId,
      if (sequence != null) 'sequence': sequence,
    });
  }

  GraphicsReferencesCompanion copyWith(
      {Value<int>? sid, Value<int>? referenceId, Value<int>? sequence}) {
    return GraphicsReferencesCompanion(
      sid: sid ?? this.sid,
      referenceId: referenceId ?? this.referenceId,
      sequence: sequence ?? this.sequence,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sid.present) {
      map['sid'] = Variable<int>(sid.value);
    }
    if (referenceId.present) {
      map['reference_id'] = Variable<int>(referenceId.value);
    }
    if (sequence.present) {
      map['sequence'] = Variable<int>(sequence.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GraphicsReferencesCompanion(')
          ..write('sid: $sid, ')
          ..write('referenceId: $referenceId, ')
          ..write('sequence: $sequence')
          ..write(')'))
        .toString();
  }
}

class $GraphicsInfosTable extends GraphicsInfos
    with TableInfo<$GraphicsInfosTable, GraphicsInfo> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GraphicsInfosTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
      'key', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _referenceIdMeta =
      const VerificationMeta('referenceId');
  @override
  late final GeneratedColumn<int> referenceId = GeneratedColumn<int>(
      'reference_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _sequenceMeta =
      const VerificationMeta('sequence');
  @override
  late final GeneratedColumn<int> sequence = GeneratedColumn<int>(
      'sequence', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _imageDataMeta =
      const VerificationMeta('imageData');
  @override
  late final GeneratedColumn<Uint8List> imageData = GeneratedColumn<Uint8List>(
      'image_data', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [key, referenceId, sequence, imageData];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'graphics_infos';
  @override
  VerificationContext validateIntegrity(Insertable<GraphicsInfo> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
          _keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('reference_id')) {
      context.handle(
          _referenceIdMeta,
          referenceId.isAcceptableOrUnknown(
              data['reference_id']!, _referenceIdMeta));
    } else if (isInserting) {
      context.missing(_referenceIdMeta);
    }
    if (data.containsKey('sequence')) {
      context.handle(_sequenceMeta,
          sequence.isAcceptableOrUnknown(data['sequence']!, _sequenceMeta));
    } else if (isInserting) {
      context.missing(_sequenceMeta);
    }
    if (data.containsKey('image_data')) {
      context.handle(_imageDataMeta,
          imageData.isAcceptableOrUnknown(data['image_data']!, _imageDataMeta));
    } else if (isInserting) {
      context.missing(_imageDataMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  GraphicsInfo map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GraphicsInfo(
      key: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      referenceId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}reference_id'])!,
      sequence: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}sequence'])!,
      imageData: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}image_data'])!,
    );
  }

  @override
  $GraphicsInfosTable createAlias(String alias) {
    return $GraphicsInfosTable(attachedDatabase, alias);
  }
}

class GraphicsInfo extends DataClass implements Insertable<GraphicsInfo> {
  final String key;
  final int referenceId;
  final int sequence;
  final Uint8List imageData;
  const GraphicsInfo(
      {required this.key,
      required this.referenceId,
      required this.sequence,
      required this.imageData});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['reference_id'] = Variable<int>(referenceId);
    map['sequence'] = Variable<int>(sequence);
    map['image_data'] = Variable<Uint8List>(imageData);
    return map;
  }

  GraphicsInfosCompanion toCompanion(bool nullToAbsent) {
    return GraphicsInfosCompanion(
      key: Value(key),
      referenceId: Value(referenceId),
      sequence: Value(sequence),
      imageData: Value(imageData),
    );
  }

  factory GraphicsInfo.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GraphicsInfo(
      key: serializer.fromJson<String>(json['key']),
      referenceId: serializer.fromJson<int>(json['referenceId']),
      sequence: serializer.fromJson<int>(json['sequence']),
      imageData: serializer.fromJson<Uint8List>(json['imageData']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'referenceId': serializer.toJson<int>(referenceId),
      'sequence': serializer.toJson<int>(sequence),
      'imageData': serializer.toJson<Uint8List>(imageData),
    };
  }

  GraphicsInfo copyWith(
          {String? key,
          int? referenceId,
          int? sequence,
          Uint8List? imageData}) =>
      GraphicsInfo(
        key: key ?? this.key,
        referenceId: referenceId ?? this.referenceId,
        sequence: sequence ?? this.sequence,
        imageData: imageData ?? this.imageData,
      );
  GraphicsInfo copyWithCompanion(GraphicsInfosCompanion data) {
    return GraphicsInfo(
      key: data.key.present ? data.key.value : this.key,
      referenceId:
          data.referenceId.present ? data.referenceId.value : this.referenceId,
      sequence: data.sequence.present ? data.sequence.value : this.sequence,
      imageData: data.imageData.present ? data.imageData.value : this.imageData,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GraphicsInfo(')
          ..write('key: $key, ')
          ..write('referenceId: $referenceId, ')
          ..write('sequence: $sequence, ')
          ..write('imageData: $imageData')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      key, referenceId, sequence, $driftBlobEquality.hash(imageData));
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GraphicsInfo &&
          other.key == this.key &&
          other.referenceId == this.referenceId &&
          other.sequence == this.sequence &&
          $driftBlobEquality.equals(other.imageData, this.imageData));
}

class GraphicsInfosCompanion extends UpdateCompanion<GraphicsInfo> {
  final Value<String> key;
  final Value<int> referenceId;
  final Value<int> sequence;
  final Value<Uint8List> imageData;
  final Value<int> rowid;
  const GraphicsInfosCompanion({
    this.key = const Value.absent(),
    this.referenceId = const Value.absent(),
    this.sequence = const Value.absent(),
    this.imageData = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GraphicsInfosCompanion.insert({
    required String key,
    required int referenceId,
    required int sequence,
    required Uint8List imageData,
    this.rowid = const Value.absent(),
  })  : key = Value(key),
        referenceId = Value(referenceId),
        sequence = Value(sequence),
        imageData = Value(imageData);
  static Insertable<GraphicsInfo> custom({
    Expression<String>? key,
    Expression<int>? referenceId,
    Expression<int>? sequence,
    Expression<Uint8List>? imageData,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (referenceId != null) 'reference_id': referenceId,
      if (sequence != null) 'sequence': sequence,
      if (imageData != null) 'image_data': imageData,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GraphicsInfosCompanion copyWith(
      {Value<String>? key,
      Value<int>? referenceId,
      Value<int>? sequence,
      Value<Uint8List>? imageData,
      Value<int>? rowid}) {
    return GraphicsInfosCompanion(
      key: key ?? this.key,
      referenceId: referenceId ?? this.referenceId,
      sequence: sequence ?? this.sequence,
      imageData: imageData ?? this.imageData,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (referenceId.present) {
      map['reference_id'] = Variable<int>(referenceId.value);
    }
    if (sequence.present) {
      map['sequence'] = Variable<int>(sequence.value);
    }
    if (imageData.present) {
      map['image_data'] = Variable<Uint8List>(imageData.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GraphicsInfosCompanion(')
          ..write('key: $key, ')
          ..write('referenceId: $referenceId, ')
          ..write('sequence: $sequence, ')
          ..write('imageData: $imageData, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$OrbitDatabase extends GeneratedDatabase {
  _$OrbitDatabase(QueryExecutor e) : super(e);
  $OrbitDatabaseManager get managers => $OrbitDatabaseManager(this);
  late final $SaveDataEntriesTable saveDataEntries =
      $SaveDataEntriesTable(this);
  late final $GraphicsReferencesTable graphicsReferences =
      $GraphicsReferencesTable(this);
  late final $GraphicsInfosTable graphicsInfos = $GraphicsInfosTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [saveDataEntries, graphicsReferences, graphicsInfos];
}

typedef $$SaveDataEntriesTableCreateCompanionBuilder = SaveDataEntriesCompanion
    Function({
  required String key,
  required String valueJson,
  Value<int> rowid,
});
typedef $$SaveDataEntriesTableUpdateCompanionBuilder = SaveDataEntriesCompanion
    Function({
  Value<String> key,
  Value<String> valueJson,
  Value<int> rowid,
});

class $$SaveDataEntriesTableFilterComposer
    extends Composer<_$OrbitDatabase, $SaveDataEntriesTable> {
  $$SaveDataEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get valueJson => $composableBuilder(
      column: $table.valueJson, builder: (column) => ColumnFilters(column));
}

class $$SaveDataEntriesTableOrderingComposer
    extends Composer<_$OrbitDatabase, $SaveDataEntriesTable> {
  $$SaveDataEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get valueJson => $composableBuilder(
      column: $table.valueJson, builder: (column) => ColumnOrderings(column));
}

class $$SaveDataEntriesTableAnnotationComposer
    extends Composer<_$OrbitDatabase, $SaveDataEntriesTable> {
  $$SaveDataEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get valueJson =>
      $composableBuilder(column: $table.valueJson, builder: (column) => column);
}

class $$SaveDataEntriesTableTableManager extends RootTableManager<
    _$OrbitDatabase,
    $SaveDataEntriesTable,
    SaveDataEntry,
    $$SaveDataEntriesTableFilterComposer,
    $$SaveDataEntriesTableOrderingComposer,
    $$SaveDataEntriesTableAnnotationComposer,
    $$SaveDataEntriesTableCreateCompanionBuilder,
    $$SaveDataEntriesTableUpdateCompanionBuilder,
    (
      SaveDataEntry,
      BaseReferences<_$OrbitDatabase, $SaveDataEntriesTable, SaveDataEntry>
    ),
    SaveDataEntry,
    PrefetchHooks Function()> {
  $$SaveDataEntriesTableTableManager(
      _$OrbitDatabase db, $SaveDataEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SaveDataEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SaveDataEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SaveDataEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> valueJson = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SaveDataEntriesCompanion(
            key: key,
            valueJson: valueJson,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required String valueJson,
            Value<int> rowid = const Value.absent(),
          }) =>
              SaveDataEntriesCompanion.insert(
            key: key,
            valueJson: valueJson,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SaveDataEntriesTableProcessedTableManager = ProcessedTableManager<
    _$OrbitDatabase,
    $SaveDataEntriesTable,
    SaveDataEntry,
    $$SaveDataEntriesTableFilterComposer,
    $$SaveDataEntriesTableOrderingComposer,
    $$SaveDataEntriesTableAnnotationComposer,
    $$SaveDataEntriesTableCreateCompanionBuilder,
    $$SaveDataEntriesTableUpdateCompanionBuilder,
    (
      SaveDataEntry,
      BaseReferences<_$OrbitDatabase, $SaveDataEntriesTable, SaveDataEntry>
    ),
    SaveDataEntry,
    PrefetchHooks Function()>;
typedef $$GraphicsReferencesTableCreateCompanionBuilder
    = GraphicsReferencesCompanion Function({
  Value<int> sid,
  required int referenceId,
  required int sequence,
});
typedef $$GraphicsReferencesTableUpdateCompanionBuilder
    = GraphicsReferencesCompanion Function({
  Value<int> sid,
  Value<int> referenceId,
  Value<int> sequence,
});

class $$GraphicsReferencesTableFilterComposer
    extends Composer<_$OrbitDatabase, $GraphicsReferencesTable> {
  $$GraphicsReferencesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get sid => $composableBuilder(
      column: $table.sid, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get referenceId => $composableBuilder(
      column: $table.referenceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sequence => $composableBuilder(
      column: $table.sequence, builder: (column) => ColumnFilters(column));
}

class $$GraphicsReferencesTableOrderingComposer
    extends Composer<_$OrbitDatabase, $GraphicsReferencesTable> {
  $$GraphicsReferencesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get sid => $composableBuilder(
      column: $table.sid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get referenceId => $composableBuilder(
      column: $table.referenceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sequence => $composableBuilder(
      column: $table.sequence, builder: (column) => ColumnOrderings(column));
}

class $$GraphicsReferencesTableAnnotationComposer
    extends Composer<_$OrbitDatabase, $GraphicsReferencesTable> {
  $$GraphicsReferencesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get sid =>
      $composableBuilder(column: $table.sid, builder: (column) => column);

  GeneratedColumn<int> get referenceId => $composableBuilder(
      column: $table.referenceId, builder: (column) => column);

  GeneratedColumn<int> get sequence =>
      $composableBuilder(column: $table.sequence, builder: (column) => column);
}

class $$GraphicsReferencesTableTableManager extends RootTableManager<
    _$OrbitDatabase,
    $GraphicsReferencesTable,
    GraphicsReference,
    $$GraphicsReferencesTableFilterComposer,
    $$GraphicsReferencesTableOrderingComposer,
    $$GraphicsReferencesTableAnnotationComposer,
    $$GraphicsReferencesTableCreateCompanionBuilder,
    $$GraphicsReferencesTableUpdateCompanionBuilder,
    (
      GraphicsReference,
      BaseReferences<_$OrbitDatabase, $GraphicsReferencesTable,
          GraphicsReference>
    ),
    GraphicsReference,
    PrefetchHooks Function()> {
  $$GraphicsReferencesTableTableManager(
      _$OrbitDatabase db, $GraphicsReferencesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GraphicsReferencesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GraphicsReferencesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GraphicsReferencesTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> sid = const Value.absent(),
            Value<int> referenceId = const Value.absent(),
            Value<int> sequence = const Value.absent(),
          }) =>
              GraphicsReferencesCompanion(
            sid: sid,
            referenceId: referenceId,
            sequence: sequence,
          ),
          createCompanionCallback: ({
            Value<int> sid = const Value.absent(),
            required int referenceId,
            required int sequence,
          }) =>
              GraphicsReferencesCompanion.insert(
            sid: sid,
            referenceId: referenceId,
            sequence: sequence,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$GraphicsReferencesTableProcessedTableManager = ProcessedTableManager<
    _$OrbitDatabase,
    $GraphicsReferencesTable,
    GraphicsReference,
    $$GraphicsReferencesTableFilterComposer,
    $$GraphicsReferencesTableOrderingComposer,
    $$GraphicsReferencesTableAnnotationComposer,
    $$GraphicsReferencesTableCreateCompanionBuilder,
    $$GraphicsReferencesTableUpdateCompanionBuilder,
    (
      GraphicsReference,
      BaseReferences<_$OrbitDatabase, $GraphicsReferencesTable,
          GraphicsReference>
    ),
    GraphicsReference,
    PrefetchHooks Function()>;
typedef $$GraphicsInfosTableCreateCompanionBuilder = GraphicsInfosCompanion
    Function({
  required String key,
  required int referenceId,
  required int sequence,
  required Uint8List imageData,
  Value<int> rowid,
});
typedef $$GraphicsInfosTableUpdateCompanionBuilder = GraphicsInfosCompanion
    Function({
  Value<String> key,
  Value<int> referenceId,
  Value<int> sequence,
  Value<Uint8List> imageData,
  Value<int> rowid,
});

class $$GraphicsInfosTableFilterComposer
    extends Composer<_$OrbitDatabase, $GraphicsInfosTable> {
  $$GraphicsInfosTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get referenceId => $composableBuilder(
      column: $table.referenceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get sequence => $composableBuilder(
      column: $table.sequence, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get imageData => $composableBuilder(
      column: $table.imageData, builder: (column) => ColumnFilters(column));
}

class $$GraphicsInfosTableOrderingComposer
    extends Composer<_$OrbitDatabase, $GraphicsInfosTable> {
  $$GraphicsInfosTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
      column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get referenceId => $composableBuilder(
      column: $table.referenceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get sequence => $composableBuilder(
      column: $table.sequence, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get imageData => $composableBuilder(
      column: $table.imageData, builder: (column) => ColumnOrderings(column));
}

class $$GraphicsInfosTableAnnotationComposer
    extends Composer<_$OrbitDatabase, $GraphicsInfosTable> {
  $$GraphicsInfosTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<int> get referenceId => $composableBuilder(
      column: $table.referenceId, builder: (column) => column);

  GeneratedColumn<int> get sequence =>
      $composableBuilder(column: $table.sequence, builder: (column) => column);

  GeneratedColumn<Uint8List> get imageData =>
      $composableBuilder(column: $table.imageData, builder: (column) => column);
}

class $$GraphicsInfosTableTableManager extends RootTableManager<
    _$OrbitDatabase,
    $GraphicsInfosTable,
    GraphicsInfo,
    $$GraphicsInfosTableFilterComposer,
    $$GraphicsInfosTableOrderingComposer,
    $$GraphicsInfosTableAnnotationComposer,
    $$GraphicsInfosTableCreateCompanionBuilder,
    $$GraphicsInfosTableUpdateCompanionBuilder,
    (
      GraphicsInfo,
      BaseReferences<_$OrbitDatabase, $GraphicsInfosTable, GraphicsInfo>
    ),
    GraphicsInfo,
    PrefetchHooks Function()> {
  $$GraphicsInfosTableTableManager(
      _$OrbitDatabase db, $GraphicsInfosTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GraphicsInfosTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GraphicsInfosTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GraphicsInfosTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<int> referenceId = const Value.absent(),
            Value<int> sequence = const Value.absent(),
            Value<Uint8List> imageData = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              GraphicsInfosCompanion(
            key: key,
            referenceId: referenceId,
            sequence: sequence,
            imageData: imageData,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String key,
            required int referenceId,
            required int sequence,
            required Uint8List imageData,
            Value<int> rowid = const Value.absent(),
          }) =>
              GraphicsInfosCompanion.insert(
            key: key,
            referenceId: referenceId,
            sequence: sequence,
            imageData: imageData,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$GraphicsInfosTableProcessedTableManager = ProcessedTableManager<
    _$OrbitDatabase,
    $GraphicsInfosTable,
    GraphicsInfo,
    $$GraphicsInfosTableFilterComposer,
    $$GraphicsInfosTableOrderingComposer,
    $$GraphicsInfosTableAnnotationComposer,
    $$GraphicsInfosTableCreateCompanionBuilder,
    $$GraphicsInfosTableUpdateCompanionBuilder,
    (
      GraphicsInfo,
      BaseReferences<_$OrbitDatabase, $GraphicsInfosTable, GraphicsInfo>
    ),
    GraphicsInfo,
    PrefetchHooks Function()>;

class $OrbitDatabaseManager {
  final _$OrbitDatabase _db;
  $OrbitDatabaseManager(this._db);
  $$SaveDataEntriesTableTableManager get saveDataEntries =>
      $$SaveDataEntriesTableTableManager(_db, _db.saveDataEntries);
  $$GraphicsReferencesTableTableManager get graphicsReferences =>
      $$GraphicsReferencesTableTableManager(_db, _db.graphicsReferences);
  $$GraphicsInfosTableTableManager get graphicsInfos =>
      $$GraphicsInfosTableTableManager(_db, _db.graphicsInfos);
}
