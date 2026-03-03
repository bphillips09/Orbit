// Weather Alerts Handler
import 'dart:convert';
import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/baudot.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/data/rfd.dart';
import 'package:orbit/data/weather/tabular_weather_state.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';

class WeatherAlertsHandler extends DSIHandler {
  WeatherAlertsHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.sxmWeatherAlerts, sxiLayer) {
    _activeInstance = this;
  }

  static const bool _traceCarid1 = true;
  static WeatherAlertsHandler? _activeInstance;
  static WeatherAlertsHandler? get activeInstance => _activeInstance;

  final Map<String, _WeatherAlertSectionAssembly> _assemblies =
      <String, _WeatherAlertSectionAssembly>{};
  final RfdCollector _rfdCollector = RfdCollector();
  bool _metadataProcessed = false;
  int? _lastMetadataCrc;
  _WeatherAlertLexicon _lexicon = const _WeatherAlertLexicon.empty();

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    _activeInstance = this;
    final List<int> body = unit.getHeaderAndData();
    if (body.isEmpty) return;

    final BitBuffer b = BitBuffer(body);
    final int pvn = b.readBits(4);
    final int carid = b.readBits(3);
    if (b.hasError) return;
    if (pvn != 1) return;

    if (carid == 2) {
      logger.i(
        'WeatherAlertsHandler: CARID2 update chunk recv bytes=${body.length} '
        'schemas=${_lexicon.tables.length}',
      );
      _handleRfdData(b);
      return;
    }
    if (carid == 3) {
      logger.i(
        'WeatherAlertsHandler: CARID3 metadata recv bytes=${body.length} '
        'schemas=${_lexicon.tables.length}',
      );
      if (_metadataProcessed && _lastMetadataCrc == unit.crc) {
        return;
      }
      final bool started = _handleRfdMetadata(b);
      if (started) {
        _metadataProcessed = true;
        _lastMetadataCrc = unit.crc;
      }
      return;
    }

    if (carid != 0 && carid != 1) {
      return;
    }

    final _ParsedWeatherAlertPart? parsed = _parseAlertPart(
      b: b,
      pvn: pvn,
      carid: carid,
      rawAu: body,
    );
    if (_traceCarid1 && carid == 1) {
      _traceCarid1Au(rawAu: body, parsed: parsed);
    }
    if (parsed == null) return;

    final WeatherAlertMessage? full = _ingestPart(parsed);
    if (full == null) return;

    sxiLayer.appState.tabularWeatherState
        .ingestWeatherAlert(_enrichWithLexicon(full));
    logger.i(
      'WeatherAlertsHandler: alert received carid=$carid '
      'msg=${full.messageId} sec=${full.sectionIndex}/${full.sectionCount} '
      'type=${full.alertTypeId} lang=${weatherAlertLanguageLabel(full.languageId)} '
      'locs=${full.locationIds.length} text=${full.alertText?.isNotEmpty == true}',
    );
  }

  _ParsedWeatherAlertPart? _parseAlertPart({
    required BitBuffer b,
    required int pvn,
    required int carid,
    required List<int> rawAu,
  }) {
    final int stateBit = b.readBits(1) & 0x1;
    final int messageId = b.readBits(7) & 0x7F;
    final int languageId = b.readBits(3) & 0x7;
    final int priority = b.readBits(4) & 0xF;
    if (b.hasError) return null;

    int sectionIndex = 1;
    int sectionCount = 1;
    final int hasCompactCounts = b.readBits(1);
    if (hasCompactCounts == 0) {
      // Single-section alert
    } else {
      final int nbits = (b.readBits(4) + 1) & 0x1F;
      if (nbits <= 0 || nbits > 16) return null;
      sectionIndex = b.readBits(nbits) + 1;
      sectionCount = b.readBits(nbits);
      if (sectionIndex < 1 || sectionIndex > 0x32 || sectionCount > 0x31) {
        return null;
      }
    }
    if (b.hasError) return null;

    final int alertTypeId = b.readBits(16) & 0xFFFF;
    final int locationScopeId = b.readBits(5) & 0x1F;
    final int locationIdBits = (b.readBits(4) + 1) & 0x1F;
    final int locationEntryCount = (b.readBits(8) + 1) & 0xFF;
    if (b.hasError) return null;
    if (locationIdBits <= 0 || locationIdBits > 24) return null;
    if (locationScopeId > 0x17 || locationEntryCount <= 0) return null;

    final List<int> locationIds = <int>[];
    for (int i = 0; i < locationEntryCount; i++) {
      final int locationId = b.readBits(locationIdBits);
      if (b.hasError) break;
      if (locationId == 0) {
        // 0 is an end marker for entry list
        break;
      }
      locationIds.add(locationId);

      // Skip per-entry fields not decoded in this first pass
      b.readBits(8);
      b.readBits(8);
      b.readBits(5);
      b.readBits(7);
      final int hasExtra = b.readBits(1);
      if (hasExtra == 1) {
        b.readBits(8);
      }
      if (b.hasError) break;
    }

    final List<int> sectionPayload = b.readRemainingBitsAsBytes();

    return _ParsedWeatherAlertPart(
      receivedAt: DateTime.now(),
      pvn: pvn,
      carid: carid,
      messageId: messageId,
      stateBit: stateBit,
      sectionIndex: sectionIndex,
      sectionCount: sectionCount,
      languageId: languageId,
      priority: priority,
      alertTypeId: alertTypeId,
      locationScopeId: locationScopeId,
      locationIds: locationIds,
      sectionPayload: sectionPayload,
      payloadLengthBytes: rawAu.length,
      rawAu: List<int>.from(rawAu),
    );
  }

  void _traceCarid1Au({
    required List<int> rawAu,
    required _ParsedWeatherAlertPart? parsed,
  }) {
    final String base =
        decodeRawAlertPayloadForDebug(rawAu, parsedOk: parsed != null);
    final _DecodedAlertCore? core = _decodeAlertCore(rawAu);
    final String tableDecode = core == null
        ? 'unavailable'
        : _decodeBinaryObjectPayload(core.payloadBytes,
            languageId: core.languageId);
    logger.i(
      '$base tableDecode=$tableDecode '
      'schemas=${_lexicon.tables.length}',
    );
  }

  static String decodeRawAlertPayloadForDebug(
    List<int> rawAu, {
    bool? parsedOk,
  }) {
    final _WeatherBitCursor c = _WeatherBitCursor(rawAu);
    if (!c.canRead(7)) {
      return 'WeatherAlertsHandler[trace]: AU too short (${rawAu.length} bytes)';
    }
    final int pvn = c.readBits(4);
    final int carid = c.readBits(3);
    if (pvn != 1 || carid != 1) {
      return 'WeatherAlertsHandler[trace]: not CARID1 (pvn=$pvn carid=$carid bytes=${rawAu.length})';
    }

    final int stateBit = c.readBits(1);
    final int messageId = c.readBits(7);
    final int languageId = c.readBits(3);
    final int priority = c.readBits(4);
    final int hasCompactCounts = c.readBits(1);
    int sectionIndex = 1;
    int sectionCount = 1;
    int? nbits;
    if (hasCompactCounts == 1) {
      nbits = c.readBits(4) + 1;
      if (nbits > 0) {
        sectionIndex = c.readBits(nbits) + 1;
        sectionCount = c.readBits(nbits);
      }
    }
    final int alertTypeId = c.readBits(16);
    final int locationScopeId = c.readBits(5);
    final int locationIdBits = c.readBits(4) + 1;
    final int locationEntryCount = c.readBits(8) + 1;
    final List<int> locationIds = <int>[];
    int entriesDecoded = 0;
    for (int i = 0; i < locationEntryCount; i++) {
      if (!c.canRead(locationIdBits)) break;
      final int locationId = c.readBits(locationIdBits);
      entriesDecoded++;
      if (locationId == 0) break;
      if (locationIds.length < 16) locationIds.add(locationId);
      if (!c.canRead(8 + 8 + 5 + 7 + 1)) break;
      c.readBits(8);
      c.readBits(8);
      c.readBits(5);
      c.readBits(7);
      final int hasExtra = c.readBits(1);
      if (hasExtra == 1 && c.canRead(8)) {
        c.readBits(8);
      }
    }

    final int payloadBitOffset = c.bitPosition;
    final int payloadBytes = (c.remainingBits / 8).floor();
    final String payloadPreview =
        _hexPreviewStatic(rawAu, startBit: payloadBitOffset, maxBytes: 48);
    return 'WeatherAlertsHandler[trace]: '
        'msg=$messageId state=$stateBit lang=$languageId pri=$priority '
        'sec=$sectionIndex/$sectionCount nbits=${nbits ?? 0} '
        'type=$alertTypeId scope=$locationScopeId '
        'locBits=$locationIdBits locEntries=$locationEntryCount decoded=$entriesDecoded '
        'locSample=${locationIds.join(",")} payloadOffBits=$payloadBitOffset '
        'payloadBytes~$payloadBytes parsedOk=${parsedOk ?? false} '
        'payloadPreview=$payloadPreview';
  }

  String decodeRawAlertPayloadWithContext(List<int> rawAu) {
    final _DecodedAlertCore? core = _decodeAlertCore(rawAu);
    final String base =
        decodeRawAlertPayloadForDebug(rawAu, parsedOk: core != null);
    if (core == null) return '$base tableDecode=unavailable';
    final String tableDecode = _decodeBinaryObjectPayload(
      core.payloadBytes,
      languageId: core.languageId,
    );
    return '$base tableDecode=$tableDecode';
  }

  _DecodedAlertCore? _decodeAlertCore(List<int> rawAu) {
    final _WeatherBitCursor c = _WeatherBitCursor(rawAu);
    if (!c.canRead(7)) return null;
    final int pvn = c.readBits(4);
    final int carid = c.readBits(3);
    if (pvn != 1 || (carid != 0 && carid != 1)) return null;
    c.readBits(1); // State
    c.readBits(7); // Message ID
    final int languageId = c.readBits(3);
    c.readBits(4); // Priority
    final int hasCompactCounts = c.readBits(1);
    if (hasCompactCounts == 1) {
      final int nbits = c.readBits(4) + 1;
      if (nbits > 0) {
        c.readBits(nbits); // Section index
        c.readBits(nbits); // Section count
      }
    }
    c.readBits(16); // Alert type ID
    c.readBits(5); // Location scope
    final int locationIdBits = c.readBits(4) + 1;
    final int locationEntryCount = c.readBits(8) + 1;
    for (int i = 0; i < locationEntryCount; i++) {
      if (!c.canRead(locationIdBits)) break;
      final int locationId = c.readBits(locationIdBits);
      if (locationId == 0) break;
      if (!c.canRead(8 + 8 + 5 + 7 + 1)) break;
      c.readBits(8);
      c.readBits(8);
      c.readBits(5);
      c.readBits(7);
      final int hasExtra = c.readBits(1);
      if (hasExtra == 1 && c.canRead(8)) {
        c.readBits(8);
      }
    }
    final int payloadBitOffset = c.bitPosition;
    final List<int> payloadBytes = _extractBitsAsBytes(rawAu, payloadBitOffset);
    return _DecodedAlertCore(
      languageId: languageId,
      payloadBytes: payloadBytes,
    );
  }

  static List<int> _extractBitsAsBytes(List<int> bytes, int startBit) {
    if (startBit >= bytes.length * 8) return const <int>[];
    final _WeatherBitCursor c = _WeatherBitCursor(bytes, bitOffset: startBit);
    int rem = c.remainingBits;
    final List<int> out = <int>[];
    while (rem >= 8) {
      out.add(c.readBits(8) & 0xFF);
      rem -= 8;
    }
    if (rem > 0) {
      out.add((c.readBits(rem) << (8 - rem)) & 0xFF);
    }
    return out;
  }

  String _decodeBinaryObjectPayload(
    List<int> payloadBytes, {
    required int languageId,
  }) {
    if (payloadBytes.isEmpty) return 'empty-payload';
    if (_lexicon.tables.isEmpty) return 'no-table-schema-loaded';
    final List<_WeatherParsedTable> candidates = _lexicon.tables
        .where((t) => t.descriptor.languageId == languageId)
        .toList(growable: false);
    final List<_WeatherParsedTable> probe =
        candidates.isNotEmpty ? candidates : _lexicon.tables;
    _PayloadDecodeAttempt? best;
    for (final _WeatherParsedTable t in probe.take(12)) {
      final _PayloadDecodeAttempt attempt =
          _tryDecodePayloadWithTable(payloadBytes, t);
      if (best == null || attempt.score > best.score) {
        best = attempt;
      }
    }
    if (best == null || best.recordsDecoded <= 0) return 'no-decode-match';
    final String typeSample = best.types.isEmpty
        ? '-'
        : '${best.types.first.id}:${best.types.first.title}';
    final String locationSample = best.locations.isEmpty
        ? '-'
        : '${best.locations.first.id}:${best.locations.first.shortName}#pts${best.locations.first.pointCount}';
    final String objectSample = best.objects.isEmpty
        ? '-'
        : '${best.objects.first.id}:${best.objects.first.summary}';
    return 'cls=${best.table.descriptor.cls} '
        'lang=${best.table.descriptor.languageId} '
        'kind=${best.table.descriptor.tableKind} '
        'records=${best.recordsDecoded} '
        'consumedBits=${best.consumedBits} '
        'types=${best.types.length} '
        'locations=${best.locations.length} '
        'objects=${best.objects.length} '
        'polygons=${best.polygons.length} '
        'typeSample=$typeSample '
        'locationSample=$locationSample '
        'objectSample=$objectSample '
        'text=${best.textSamples.isEmpty ? "-" : best.textSamples.join(" | ")}';
  }

  _PayloadDecodeAttempt _tryDecodePayloadWithTable(
    List<int> payloadBytes,
    _WeatherParsedTable table,
  ) {
    final _WeatherBitCursor c = _WeatherBitCursor(payloadBytes);
    if (table.fields.isEmpty) {
      return _PayloadDecodeAttempt(
        table: table,
        recordsDecoded: 0,
        consumedBits: 0,
        hardErrors: 1,
        textSamples: const <String>[],
        types: const <_RecoveredAlertType>[],
        locations: const <_RecoveredAlertLocation>[],
        objects: const <_RecoveredAlertObject>[],
        polygons: const <_RecoveredAlertPolygon>[],
      );
    }
    int records = 0;
    int hardErrors = 0;
    final List<String> textSamples = <String>[];
    final List<_RecoveredAlertType> types = <_RecoveredAlertType>[];
    final List<_RecoveredAlertLocation> locations = <_RecoveredAlertLocation>[];
    final List<_RecoveredAlertObject> objects = <_RecoveredAlertObject>[];
    final List<_RecoveredAlertPolygon> polygons = <_RecoveredAlertPolygon>[];
    for (int guard = 0; guard < 64; guard++) {
      if (!c.canRead(2)) break;
      final int op = c.readBits(2);
      if (op == 3) break;
      final _WeatherFieldValue key = c.readField(table.fields.first);
      if (key.hardError || key.asRecordId == null) {
        hardErrors++;
        break;
      }
      if (op != 0) {
        final Map<String, dynamic> recordFields = <String, dynamic>{};
        for (int i = 1; i < table.fields.length; i++) {
          final _WeatherFieldDef f = table.fields[i];
          final _WeatherFieldValue v = c.readField(f);
          if (v.hardError) {
            hardErrors++;
            break;
          }
          recordFields[f.name] = v.value;
          final String? text = v.textCandidate;
          if (text != null && textSamples.length < 4) {
            textSamples.add(text);
          }
        }
        if (hardErrors == 0) {
          final int recordId = key.asRecordId ?? -1;
          if (recordId >= 0) {
            final _RecoveredRecordSet recovered = _recoverRecordTypes(
              table: table,
              recordId: recordId,
              fields: recordFields,
            );
            types.addAll(recovered.types);
            locations.addAll(recovered.locations);
            objects.addAll(recovered.objects);
            polygons.addAll(recovered.polygons);
          }
        }
      }
      records++;
      if (hardErrors > 0) break;
    }
    return _PayloadDecodeAttempt(
      table: table,
      recordsDecoded: records,
      consumedBits: c.bitPosition,
      hardErrors: hardErrors,
      textSamples: textSamples,
      types: types,
      locations: locations,
      objects: objects,
      polygons: polygons,
    );
  }

  _RecoveredRecordSet _recoverRecordTypes({
    required _WeatherParsedTable table,
    required int recordId,
    required Map<String, dynamic> fields,
  }) {
    final List<String> textFields = fields.values
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.length >= 3)
        .toList(growable: false);
    final String title = textFields.isNotEmpty ? textFields.first : '';
    final String details = textFields.length > 1 ? textFields[1] : '';

    if (table.descriptor.cls == 0) {
      return _RecoveredRecordSet(
        types: <_RecoveredAlertType>[
          _RecoveredAlertType(
            id: recordId,
            languageId: table.descriptor.languageId,
            title: title,
            details: details,
          ),
        ],
      );
    }

    if (table.descriptor.cls == 1) {
      final List<int>? lat = _arrayByName(fields, 'lat');
      final List<int>? lon = _arrayByName(fields, 'lon');
      final List<_RecoveredAlertPolygonPoint> points =
          <_RecoveredAlertPolygonPoint>[];
      if (lat != null && lon != null && lat.length == lon.length) {
        for (int i = 0; i < lat.length; i++) {
          points.add(_RecoveredAlertPolygonPoint(
            lat: lat[i] * 3.0517578125e-05,
            lon: lon[i] * 3.0517578125e-05,
          ));
        }
      }
      final _RecoveredAlertPolygon? poly = points.isNotEmpty
          ? _RecoveredAlertPolygon(
              id: recordId,
              locationId: recordId,
              points: points,
            )
          : null;
      return _RecoveredRecordSet(
        locations: <_RecoveredAlertLocation>[
          _RecoveredAlertLocation(
            id: recordId,
            languageId: table.descriptor.languageId,
            shortName: title,
            longName: details,
            pointCount: points.length,
          ),
        ],
        polygons: poly == null
            ? const <_RecoveredAlertPolygon>[]
            : <_RecoveredAlertPolygon>[poly],
      );
    }

    if (table.descriptor.cls == 2) {
      final List<int> refs = fields.values
          .whereType<List<int>>()
          .expand((v) => v)
          .take(8)
          .toList(growable: false);
      return _RecoveredRecordSet(
        objects: <_RecoveredAlertObject>[
          _RecoveredAlertObject(
            id: recordId,
            languageId: table.descriptor.languageId,
            summary: title,
            refs: refs,
          ),
        ],
      );
    }

    return const _RecoveredRecordSet();
  }

  List<int>? _arrayByName(Map<String, dynamic> fields, String name) {
    for (final MapEntry<String, dynamic> e in fields.entries) {
      if (e.key.toLowerCase().contains(name) && e.value is List<int>) {
        return e.value as List<int>;
      }
    }
    return null;
  }

  static String _hexPreviewStatic(List<int> rawAu,
      {required int startBit, int maxBytes = 48}) {
    final int startByte = (startBit / 8).floor();
    if (startByte >= rawAu.length) return '';
    final int end = (startByte + maxBytes) < rawAu.length
        ? startByte + maxBytes
        : rawAu.length;
    final Iterable<int> slice = rawAu.sublist(startByte, end);
    return slice.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  WeatherAlertMessage? _ingestPart(_ParsedWeatherAlertPart part) {
    final String key =
        '${part.carid}:${part.messageId}:${part.languageId}:${part.alertTypeId}:${part.locationScopeId}';
    final DateTime now = DateTime.now();
    _assemblies.removeWhere(
      (_, a) => a.lastUpdated.add(const Duration(minutes: 5)).isBefore(now),
    );

    final String? immediateText =
        _extractAlertText(part.sectionPayload, fallbackBytes: part.rawAu);
    if (part.sectionCount <= 1 || part.sectionIndex <= 0) {
      return WeatherAlertMessage(
        receivedAt: part.receivedAt,
        pvn: part.pvn,
        carid: part.carid,
        messageId: part.messageId,
        stateBit: part.stateBit,
        sectionIndex: part.sectionIndex,
        sectionCount: part.sectionCount,
        languageId: part.languageId,
        priority: part.priority,
        alertTypeId: part.alertTypeId,
        locationScopeId: part.locationScopeId,
        locationIds: part.locationIds,
        payloadLengthBytes: part.payloadLengthBytes,
        alertText: immediateText,
        assembledFromSections: false,
        rawAu: part.rawAu,
      );
    }

    final _WeatherAlertSectionAssembly assembly = _assemblies.putIfAbsent(
      key,
      () => _WeatherAlertSectionAssembly(
        expectedCount: part.sectionCount,
        firstPart: part,
      ),
    );
    assembly.lastUpdated = now;
    if (part.sectionCount > assembly.expectedCount) {
      assembly.expectedCount = part.sectionCount;
    }
    assembly.partsByIndex[part.sectionIndex] = part;

    final bool complete = assembly.expectedCount > 0 &&
        assembly.partsByIndex.length >= assembly.expectedCount;
    if (!complete) return null;

    final List<int> mergedPayload = <int>[];
    for (int i = 1; i <= assembly.expectedCount; i++) {
      final _ParsedWeatherAlertPart? p = assembly.partsByIndex[i];
      if (p == null) {
        return null;
      }
      mergedPayload.addAll(p.sectionPayload);
    }

    final _ParsedWeatherAlertPart first = assembly.firstPart;
    _assemblies.remove(key);
    return WeatherAlertMessage(
      receivedAt: part.receivedAt,
      pvn: first.pvn,
      carid: first.carid,
      messageId: first.messageId,
      stateBit: first.stateBit,
      sectionIndex: first.sectionIndex,
      sectionCount: first.sectionCount,
      languageId: first.languageId,
      priority: first.priority,
      alertTypeId: first.alertTypeId,
      locationScopeId: first.locationScopeId,
      locationIds: first.locationIds,
      payloadLengthBytes: first.payloadLengthBytes,
      alertText: _extractAlertText(mergedPayload, fallbackBytes: first.rawAu),
      assembledFromSections: true,
      rawAu: first.rawAu,
    );
  }

  WeatherAlertMessage _enrichWithLexicon(WeatherAlertMessage alert) {
    if (alert.alertText != null && alert.alertText!.trim().isNotEmpty) {
      return alert;
    }
    final String? typeText = _lexicon.class0ById[alert.alertTypeId];
    final List<String> locationNames = alert.locationIds
        .map((id) => _lexicon.class1ById[id])
        .whereType<String>()
        .take(3)
        .toList();
    if (typeText == null && locationNames.isEmpty) {
      return alert;
    }
    final StringBuffer sb = StringBuffer();
    if (typeText != null && typeText.isNotEmpty) {
      sb.write(typeText);
    }
    if (locationNames.isNotEmpty) {
      if (sb.isNotEmpty) sb.write(' ');
      sb.write('for ${locationNames.join(', ')}');
      final int remaining = alert.locationIds.length - locationNames.length;
      if (remaining > 0) {
        sb.write(' +$remaining more');
      }
    }
    return WeatherAlertMessage(
      receivedAt: alert.receivedAt,
      pvn: alert.pvn,
      carid: alert.carid,
      messageId: alert.messageId,
      stateBit: alert.stateBit,
      sectionIndex: alert.sectionIndex,
      sectionCount: alert.sectionCount,
      languageId: alert.languageId,
      priority: alert.priority,
      alertTypeId: alert.alertTypeId,
      locationScopeId: alert.locationScopeId,
      locationIds: alert.locationIds,
      payloadLengthBytes: alert.payloadLengthBytes,
      alertText: sb.toString().trim(),
      assembledFromSections: alert.assembledFromSections,
      rawAu: alert.rawAu,
    );
  }

  bool _handleRfdMetadata(BitBuffer b) {
    final RfdMetadata meta = _parseRfdMetadataBits(b);
    if (meta.expectedSize == null || meta.expectedSize! <= 0) {
      logger.i('WeatherAlertsHandler: RFD metadata invalid/empty');
      return false;
    }
    logger.i(
      'WeatherAlertsHandler: RFD metadata parsed '
      'file=${meta.fileName ?? "-"} expected=${meta.expectedSize} block=${meta.blockSize}',
    );
    _rfdCollector.start(meta);
    return true;
  }

  void _handleRfdData(BitBuffer b) {
    b.align();
    final List<int> chunk = b.remainingData;
    if (chunk.isEmpty) return;
    final bool done = _rfdCollector.addBlockFromAu(chunk, headerLen: 5);
    logger.i(
      'WeatherAlertsHandler: RFD data chunk len=${chunk.length} done=$done',
    );
    if (!done) return;
    final List<int>? bytes = _rfdCollector.takeIfComplete();
    if (bytes == null || bytes.isEmpty) return;
    _metadataProcessed = false;
    _lastMetadataCrc = null;
    final _WeatherAlertLexicon parsed = _WeatherAlertLexicon.parse(bytes);
    if (parsed.totalEntries <= 0) {
      logger.w(
          'WeatherAlertsHandler: weather alerts update file parsed with no entries (size=${bytes.length})');
      return;
    }
    _lexicon = parsed;
    logger.i(
      'WeatherAlertsHandler: weather alerts lexicon refreshed '
      'class0=${_lexicon.class0ById.length} '
      'class1=${_lexicon.class1ById.length} '
      'class2=${_lexicon.class2ById.length} '
      'tables=${_lexicon.tables.length}',
    );
  }

  RfdMetadata _parseRfdMetadataBits(BitBuffer b) {
    final String name = BaudotDecoder.decodeFixed(b, 0x10, 0x10);
    b.readBits(32); // Metadata field
    b.readBits(4); // Flags
    final int type3 = b.readBits(3);
    final int mode3 = b.readBits(3);
    if (type3 > 2 || mode3 >= 2 || b.hasError) {
      return const RfdMetadata(
          fileName: null, expectedSize: null, raw: <int>[]);
    }
    b.readBits(14); // Another metadata field
    final int count = b.readBits(4) + 1;
    int totalSize = 0;
    int? blockSize;
    int? firstEntryId;
    for (int i = 0; i < count; i++) {
      final int id16 = b.readBits(16);
      final int blocksOrLen14 = b.readBits(14);
      final int size24 = b.readBits(24);
      b.readBits(32); // CRC32
      if (b.hasError) break;
      if (blocksOrLen14 == 0) {
        return const RfdMetadata(
            fileName: null, expectedSize: null, raw: <int>[]);
      }
      totalSize += size24;
      if (i == 0) {
        blockSize = blocksOrLen14;
        firstEntryId = id16;
      }
    }
    if (!b.hasError) {
      final int hasExtra = b.readBits(1);
      if (hasExtra == 1) {
        final int seven = b.readBits(7);
        if (seven >= 1) {
          b.readBits(10);
        }
      }
    }
    return RfdMetadata(
      fileName: name.isEmpty ? null : name,
      expectedSize: totalSize > 0 ? totalSize : null,
      blockSize: blockSize,
      fileId: firstEntryId,
      compressionMode: mode3,
      raw: const <int>[],
    );
  }

  String? _extractAlertText(List<int> bytes, {List<int>? fallbackBytes}) {
    final String? utf = _decodeUtf8Printable(bytes);
    if (utf != null) return utf;
    final String? runs = _extractAsciiRuns(bytes);
    if (runs != null) return runs;
    if (fallbackBytes != null) {
      return _extractAsciiRuns(fallbackBytes);
    }
    return null;
  }

  String? _decodeUtf8Printable(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      final String s = utf8.decode(bytes, allowMalformed: true);
      final String cleaned = s
          .replaceAll(RegExp(r'[\u0000-\u0008\u000B-\u001F\u007F]'), ' ')
          .trim();
      if (cleaned.length < 8) return null;
      final int printable = cleaned.runes
          .where(
              (r) => r == 10 || r == 13 || r == 9 || (r >= 0x20 && r <= 0x7E))
          .length;
      if (printable < (cleaned.length * 0.75)) return null;
      return cleaned.length > 500 ? cleaned.substring(0, 500) : cleaned;
    } catch (_) {
      return null;
    }
  }

  String? _extractAsciiRuns(List<int> rawAu) {
    final List<String> runs = <String>[];
    final StringBuffer current = StringBuffer();
    for (final int b in rawAu) {
      final bool printable = b >= 0x20 && b <= 0x7E;
      if (printable) {
        current.writeCharCode(b);
      } else {
        if (current.length >= 8) {
          runs.add(current.toString());
        }
        current.clear();
      }
    }
    if (current.length >= 8) {
      runs.add(current.toString());
    }
    if (runs.isEmpty) return null;
    return runs.join(' ').trim();
  }
}

class _ParsedWeatherAlertPart {
  final DateTime receivedAt;
  final int pvn;
  final int carid;
  final int messageId;
  final int stateBit;
  final int sectionIndex;
  final int sectionCount;
  final int languageId;
  final int priority;
  final int alertTypeId;
  final int locationScopeId;
  final List<int> locationIds;
  final List<int> sectionPayload;
  final int payloadLengthBytes;
  final List<int> rawAu;

  const _ParsedWeatherAlertPart({
    required this.receivedAt,
    required this.pvn,
    required this.carid,
    required this.messageId,
    required this.stateBit,
    required this.sectionIndex,
    required this.sectionCount,
    required this.languageId,
    required this.priority,
    required this.alertTypeId,
    required this.locationScopeId,
    required this.locationIds,
    required this.sectionPayload,
    required this.payloadLengthBytes,
    required this.rawAu,
  });
}

class _WeatherAlertSectionAssembly {
  int expectedCount;
  final _ParsedWeatherAlertPart firstPart;
  final Map<int, _ParsedWeatherAlertPart> partsByIndex =
      <int, _ParsedWeatherAlertPart>{};
  DateTime lastUpdated;

  _WeatherAlertSectionAssembly({
    required this.expectedCount,
    required this.firstPart,
  }) : lastUpdated = DateTime.now();
}

class _DecodedAlertCore {
  final int languageId;
  final List<int> payloadBytes;

  const _DecodedAlertCore({
    required this.languageId,
    required this.payloadBytes,
  });
}

class _PayloadDecodeAttempt {
  final _WeatherParsedTable table;
  final int recordsDecoded;
  final int consumedBits;
  final int hardErrors;
  final List<String> textSamples;
  final List<_RecoveredAlertType> types;
  final List<_RecoveredAlertLocation> locations;
  final List<_RecoveredAlertObject> objects;
  final List<_RecoveredAlertPolygon> polygons;

  const _PayloadDecodeAttempt({
    required this.table,
    required this.recordsDecoded,
    required this.consumedBits,
    required this.hardErrors,
    required this.textSamples,
    required this.types,
    required this.locations,
    required this.objects,
    required this.polygons,
  });

  int get score => (recordsDecoded * 100) + consumedBits - (hardErrors * 500);
}

class _WeatherAlertLexicon {
  final Map<int, String> class0ById;
  final Map<int, String> class1ById;
  final Map<int, String> class2ById;
  final List<_WeatherParsedTable> tables;

  const _WeatherAlertLexicon({
    required this.class0ById,
    required this.class1ById,
    required this.class2ById,
    required this.tables,
  });

  const _WeatherAlertLexicon.empty()
      : class0ById = const <int, String>{},
        class1ById = const <int, String>{},
        class2ById = const <int, String>{},
        tables = const <_WeatherParsedTable>[];

  int get totalEntries =>
      class0ById.length + class1ById.length + class2ById.length;

  static _WeatherAlertLexicon parse(List<int> bytes) {
    final Map<int, String> class0 = <int, String>{};
    final Map<int, String> class1 = <int, String>{};
    final Map<int, String> class2 = <int, String>{};
    final List<_WeatherParsedTable> parsedTables = <_WeatherParsedTable>[];
    final _WeatherBitCursor header = _WeatherBitCursor(bytes);
    if (header.canRead(16)) {
      header.readBits(8); // Update file version/flags byte
      final int tableCount = (header.readBits(8) + 1).clamp(0, 256);
      final List<_WeatherTableDescriptor> tables = <_WeatherTableDescriptor>[];
      for (int i = 0; i < tableCount; i++) {
        if (!header.canRead(8 + 8 + 8 + 16 + 16 + 32)) break;
        final int cls = header.readBits(8);
        final int lang = header.readBits(8);
        final int tableKind = header.readBits(8);
        final int firstId = header.readBits(16);
        final int lastId = header.readBits(16);
        final int bitOffset = header.readBits(32);
        if (cls > 2 || tableKind > 2 || bitOffset < 0) continue;
        if (bitOffset >= bytes.length * 8) continue;
        tables.add(_WeatherTableDescriptor(
          cls: cls,
          languageId: lang,
          tableKind: tableKind,
          firstId: firstId,
          lastId: lastId,
          bitOffset: bitOffset,
        ));
      }
      for (final _WeatherTableDescriptor t in tables) {
        final _WeatherParsedTable? pt = _parseTable(bytes, t,
            class0: class0, class1: class1, class2: class2);
        if (pt != null) {
          parsedTables.add(pt);
        }
      }
    }

    // Fallback for any records that couldn't be decoded
    if (class0.isEmpty && class1.isEmpty && class2.isEmpty) {
      _parseBinaryFallback(bytes, class0, class1, class2);
    }

    return _WeatherAlertLexicon(
      class0ById: class0,
      class1ById: class1,
      class2ById: class2,
      tables: parsedTables,
    );
  }

  static String _normalizeEntryText(String s) {
    final String cleaned =
        s.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ').trim();
    if (cleaned.length < 3) return '';
    if (RegExp(r'^[0-9\W_]+$').hasMatch(cleaned)) return '';
    return cleaned;
  }

  static void _parseBinaryFallback(
    List<int> bytes,
    Map<int, String> class0,
    Map<int, String> class1,
    Map<int, String> class2,
  ) {
    for (int i = 2; i + 5 < bytes.length; i++) {
      final int idLe = (bytes[i - 2] & 0xFF) | ((bytes[i - 1] & 0xFF) << 8);
      if (idLe <= 0 || idLe > 0xFFFF) continue;
      int j = i;
      while (j < bytes.length) {
        final int c = bytes[j] & 0xFF;
        if (c < 0x20 || c > 0x7E) break;
        j++;
      }
      final int len = j - i;
      if (len < 6 || len > 96) continue;
      final String text =
          _normalizeEntryText(String.fromCharCodes(bytes.sublist(i, j)));
      if (text.isEmpty) continue;
      // Class unknown
      class0.putIfAbsent(idLe, () => text);
      class1.putIfAbsent(idLe, () => text);
      class2.putIfAbsent(idLe, () => text);
      i = j;
    }
  }

  static _WeatherParsedTable? _parseTable(
    List<int> bytes,
    _WeatherTableDescriptor table, {
    required Map<int, String> class0,
    required Map<int, String> class1,
    required Map<int, String> class2,
  }) {
    final _WeatherBitCursor c =
        _WeatherBitCursor(bytes, bitOffset: table.bitOffset);
    if (!c.canRead(6)) return null;
    final int fieldCount = (c.readBits(6) + 1).clamp(0, 64);
    final List<_WeatherFieldDef> fields = <_WeatherFieldDef>[];
    for (int i = 0; i < fieldCount; i++) {
      if (!c.canRead(8 + (33 * 5) + 3 + 12)) return null;
      c.readBits(8); // Field ID
      final String fieldName = _normalizeFieldName(c.readBaudot(33), i);
      final int kind = c.readBits(3);
      final int bitLen = c.readBits(12) + 1;
      int maxItems = 0;
      if (kind == 3) {
        if (!c.canRead(6)) return null;
        maxItems = c.readBits(6) + 1;
      }
      fields.add(_WeatherFieldDef(
        name: fieldName,
        kind: kind,
        bitLen: bitLen,
        maxItems: maxItems,
      ));
    }
    if (fields.isEmpty) return null;

    final Map<int, String> target =
        table.cls == 0 ? class0 : (table.cls == 1 ? class1 : class2);
    while (c.canRead(2)) {
      final int op = c.readBits(2);
      if (op == 3) break;

      final _WeatherFieldValue keyValue = c.readField(fields.first);
      final int? id = keyValue.asRecordId;
      if (id == null) break;
      if (op == 0) {
        target.remove(id);
        continue;
      }
      String? bestText;
      bool stop = false;
      for (int i = 1; i < fields.length; i++) {
        final _WeatherFieldValue v = c.readField(fields[i]);
        if (v.hardError) {
          stop = true;
          break;
        }
        final String? text = v.textCandidate;
        if (text != null && text.length > (bestText?.length ?? 0)) {
          bestText = text;
        }
      }
      if (stop) break;
      if (id < table.firstId || id > table.lastId) continue;
      final String normalized = _normalizeEntryText(bestText ?? '');
      if (normalized.isEmpty) continue;
      target[id] = normalized;
    }
    return _WeatherParsedTable(
      descriptor: table,
      fields: List<_WeatherFieldDef>.unmodifiable(fields),
    );
  }
}

class _WeatherTableDescriptor {
  final int cls;
  final int languageId;
  final int tableKind;
  final int firstId;
  final int lastId;
  final int bitOffset;

  const _WeatherTableDescriptor({
    required this.cls,
    required this.languageId,
    required this.tableKind,
    required this.firstId,
    required this.lastId,
    required this.bitOffset,
  });
}

class _WeatherParsedTable {
  final _WeatherTableDescriptor descriptor;
  final List<_WeatherFieldDef> fields;

  const _WeatherParsedTable({
    required this.descriptor,
    required this.fields,
  });
}

class _WeatherFieldDef {
  final String name;
  final int kind;
  final int bitLen;
  final int maxItems;

  const _WeatherFieldDef({
    required this.name,
    required this.kind,
    required this.bitLen,
    required this.maxItems,
  });
}

class _RecoveredRecordSet {
  final List<_RecoveredAlertType> types;
  final List<_RecoveredAlertLocation> locations;
  final List<_RecoveredAlertObject> objects;
  final List<_RecoveredAlertPolygon> polygons;

  const _RecoveredRecordSet({
    this.types = const <_RecoveredAlertType>[],
    this.locations = const <_RecoveredAlertLocation>[],
    this.objects = const <_RecoveredAlertObject>[],
    this.polygons = const <_RecoveredAlertPolygon>[],
  });
}

class _RecoveredAlertType {
  final int id;
  final int languageId;
  final String title;
  final String details;

  const _RecoveredAlertType({
    required this.id,
    required this.languageId,
    required this.title,
    required this.details,
  });
}

class _RecoveredAlertLocation {
  final int id;
  final int languageId;
  final String shortName;
  final String longName;
  final int pointCount;

  const _RecoveredAlertLocation({
    required this.id,
    required this.languageId,
    required this.shortName,
    required this.longName,
    required this.pointCount,
  });
}

class _RecoveredAlertObject {
  final int id;
  final int languageId;
  final String summary;
  final List<int> refs;

  const _RecoveredAlertObject({
    required this.id,
    required this.languageId,
    required this.summary,
    required this.refs,
  });
}

class _RecoveredAlertPolygon {
  final int id;
  final int locationId;
  final List<_RecoveredAlertPolygonPoint> points;

  const _RecoveredAlertPolygon({
    required this.id,
    required this.locationId,
    required this.points,
  });
}

class _RecoveredAlertPolygonPoint {
  final double lat;
  final double lon;

  const _RecoveredAlertPolygonPoint({
    required this.lat,
    required this.lon,
  });
}

class _WeatherFieldValue {
  final dynamic value;
  final bool hardError;

  const _WeatherFieldValue(this.value, {this.hardError = false});

  int? get asRecordId {
    final dynamic v = value;
    if (v is int) return v & 0xFFFF;
    return null;
  }

  String? get textCandidate {
    final dynamic v = value;
    if (v is String) {
      final String cleaned = v.trim();
      if (cleaned.length >= 3) return cleaned;
    }
    return null;
  }
}

class _WeatherBitCursor {
  final List<int> bytes;
  int _bitPos;

  _WeatherBitCursor(this.bytes, {int bitOffset = 0}) : _bitPos = bitOffset;

  bool canRead(int bits) => bits >= 0 && _bitPos + bits <= bytes.length * 8;
  int get bitPosition => _bitPos;
  int get remainingBits => (bytes.length * 8) - _bitPos;

  int readBits(int bits) {
    if (bits <= 0 || !canRead(bits)) return 0;
    int out = 0;
    for (int i = 0; i < bits; i++) {
      final int p = _bitPos + i;
      final int b = bytes[p >> 3] & 0xFF;
      final int bit = (b >> (7 - (p & 7))) & 0x1;
      out = (out << 1) | bit;
    }
    _bitPos += bits;
    return out;
  }

  String readCString({int maxLen = 512}) {
    final List<int> chars = <int>[];
    for (int i = 0; i < maxLen; i++) {
      if (!canRead(8)) break;
      final int b = readBits(8) & 0xFF;
      if (b == 0) break;
      if ((b >= 0x20 && b <= 0x7E) || b == 9 || b == 10 || b == 13) {
        chars.add(b);
      }
    }
    return String.fromCharCodes(chars);
  }

  String readBaudot(int symbols) {
    if (symbols <= 0) return '';
    final StringBuffer sb = StringBuffer();
    bool figures = false;
    for (int i = 0; i < symbols; i++) {
      if (!canRead(5)) break;
      final int code = readBits(5) & 0x1F;
      if (code == 0) break;
      if (code == 0x1F) {
        figures = !figures;
        continue;
      }
      final String ch = figures ? _baudotFigures[code] : _baudotLetters[code];
      if (ch.isNotEmpty) sb.write(ch);
    }
    return sb.toString();
  }

  _WeatherFieldValue readField(_WeatherFieldDef def) {
    if (!canRead(1)) return const _WeatherFieldValue(null, hardError: true);
    final int present = readBits(1);
    if (present == 0) return const _WeatherFieldValue(null);

    if (def.kind == 0) {
      if (!canRead(def.bitLen)) {
        return const _WeatherFieldValue(null, hardError: true);
      }
      return _WeatherFieldValue(readBits(def.bitLen));
    }
    if (def.kind == 1) {
      return _WeatherFieldValue(readCString());
    }
    if (def.kind == 2) {
      return _WeatherFieldValue(readBaudot(def.bitLen + 1));
    }
    if (def.kind == 3) {
      if (!canRead(def.bitLen)) {
        return const _WeatherFieldValue(null, hardError: true);
      }
      final int count = readBits(def.bitLen) + 1;
      if (def.maxItems > 0 && count > def.maxItems) {
        return const _WeatherFieldValue(null, hardError: true);
      }
      final List<int> values = <int>[];
      for (int i = 0; i < count; i++) {
        if (!canRead(def.bitLen)) {
          return const _WeatherFieldValue(null, hardError: true);
        }
        values.add(readBits(def.bitLen));
      }
      return _WeatherFieldValue(values);
    }
    return const _WeatherFieldValue(null, hardError: true);
  }

  static const List<String> _baudotLetters = <String>[
    '',
    'E',
    '',
    'A',
    ' ',
    'S',
    'I',
    'U',
    '',
    'D',
    'R',
    'J',
    'N',
    'F',
    'C',
    'K',
    'T',
    'Z',
    'L',
    'W',
    'H',
    'Y',
    'P',
    'Q',
    'O',
    'B',
    'G',
    '',
    'M',
    'X',
    'V',
    '',
  ];

  static const List<String> _baudotFigures = <String>[
    '',
    '3',
    '',
    '-',
    ' ',
    '\'',
    '8',
    '7',
    '',
    '\$',
    '4',
    '*',
    ',',
    '!',
    ':',
    '(',
    '5',
    '"',
    ')',
    '2',
    '#',
    '6',
    '0',
    '1',
    '9',
    '?',
    '&',
    '',
    '.',
    '/',
    ';',
    '',
  ];
}

String _normalizeFieldName(String raw, int index) {
  final String cleaned = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (cleaned.isEmpty) return 'f$index';
  return cleaned;
}

const Map<int, String> weatherAlertLanguageLabels = <int, String>{
  0: 'English',
  1: 'Spanish',
  2: 'French',
};

const Map<int, String> weatherAlertLocationScopeLabels = <int, String>{
  0: 'State',
  1: 'Marine',
  2: 'Fire',
  3: 'River Gage',
};

String weatherAlertLanguageLabel(int languageId) =>
    weatherAlertLanguageLabels[languageId] ?? 'Unknown($languageId)';

String weatherAlertLocationScopeLabel(int scopeId) =>
    weatherAlertLocationScopeLabels[scopeId] ?? 'Scope($scopeId)';
