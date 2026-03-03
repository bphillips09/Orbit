// Tabular Weather State
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:orbit/data/weather/forecast_parser.dart';
import 'package:orbit/data/weather/tabular_weather_location.dart';
import 'package:orbit/data/weather/tabular_weather_parser.dart';

class TabularWeatherState extends ChangeNotifier {
  TabularWeatherParsed? _tabularWeatherDb;
  Uint8List? _tabularWeatherDbBytes;
  String? _tabularWeatherDbFileName;
  List<TabularWeatherLocation> _tabularWeatherLocations =
      <TabularWeatherLocation>[];
  TabularWeatherLocation? _tabularWeatherSelectedLocation;
  DateTime? _tabularWeatherLastDbUpdate;
  DateTime? _tabularWeatherLastForecastUpdate;
  bool _tabularWeatherDbDownloadInProgress = false;
  int? _tabularWeatherDbExpectedBytes;
  int _tabularWeatherDbReceivedBytes = 0;
  String? _tabularWeatherDbDownloadFileName;

  final Map<int, List<int>> _tabularWeatherForecastBodiesByType =
      <int, List<int>>{};
  final Map<int, ForecastRecord?> _tabularWeatherForecastByType =
      <int, ForecastRecord?>{};
  final List<WeatherAlertMessage> _weatherAlerts = <WeatherAlertMessage>[];
  final Map<String, WeatherAlertMessage> _activeWeatherAlertsByKey =
      <String, WeatherAlertMessage>{};

  bool get hasTabularWeatherDb =>
      _tabularWeatherDb != null && _tabularWeatherLocations.isNotEmpty;
  bool get canReparseTabularWeatherDb =>
      _tabularWeatherDbBytes != null && _tabularWeatherDbBytes!.isNotEmpty;
  String? get tabularWeatherDbFileName => _tabularWeatherDbFileName;
  int get tabularWeatherDbBytesLength => _tabularWeatherDbBytes?.length ?? 0;
  Uint8List? get tabularWeatherDbBytes => _tabularWeatherDbBytes;
  int get tabularWeatherLocationCount => _tabularWeatherLocations.length;
  DateTime? get tabularWeatherLastDbUpdate => _tabularWeatherLastDbUpdate;
  DateTime? get tabularWeatherLastForecastUpdate =>
      _tabularWeatherLastForecastUpdate;

  bool get tabularWeatherDbDownloadInProgress =>
      _tabularWeatherDbDownloadInProgress;
  int? get tabularWeatherDbExpectedBytes => _tabularWeatherDbExpectedBytes;
  int get tabularWeatherDbReceivedBytes => _tabularWeatherDbReceivedBytes;
  String? get tabularWeatherDbDownloadFileName =>
      _tabularWeatherDbDownloadFileName;

  TabularWeatherLocation? get tabularWeatherSelectedLocation =>
      _tabularWeatherSelectedLocation;
  Map<int, ForecastRecord?> get tabularWeatherForecastByType =>
      UnmodifiableMapView<int, ForecastRecord?>(_tabularWeatherForecastByType);
  List<WeatherAlertMessage> get weatherAlerts =>
      UnmodifiableListView<WeatherAlertMessage>(_weatherAlerts);
  List<WeatherAlertMessage> get activeWeatherAlerts {
    final List<WeatherAlertMessage> v =
        List<WeatherAlertMessage>.from(_activeWeatherAlertsByKey.values);
    v.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return UnmodifiableListView<WeatherAlertMessage>(v);
  }

  List<TabularWeatherLocation> searchTabularWeatherLocations(String query,
      {int limit = 25}) {
    return tabularWeatherSearchLocations(_tabularWeatherLocations, query,
        limit: limit);
  }

  List<TabularWeatherLocation> tabularWeatherLocationsWithData({int? limit}) {
    if (_tabularWeatherLocations.isEmpty) {
      return const <TabularWeatherLocation>[];
    }
    if (limit != null && limit <= 0) return const <TabularWeatherLocation>[];

    final List<TabularWeatherLocation> out = <TabularWeatherLocation>[];
    for (final TabularWeatherLocation loc in _tabularWeatherLocations) {
      if (!loc.present) continue;
      if (loc.displayName.isEmpty && loc.stationId.isEmpty) continue;
      out.add(loc);
      if (limit != null && out.length >= limit) break;
    }
    return UnmodifiableListView<TabularWeatherLocation>(out);
  }

  void updateTabularWeatherDatabase(TabularWeatherParsed parsed) {
    _tabularWeatherDb = parsed;
    _tabularWeatherLocations = tabularWeatherFlattenLocations(parsed);
    _tabularWeatherLocations.sort((a, b) {
      final int c1 =
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      if (c1 != 0) return c1;
      final int c2 = a.stationId.compareTo(b.stationId);
      if (c2 != 0) return c2;
      final int c3 = a.stateId.compareTo(b.stateId);
      if (c3 != 0) return c3;
      return a.locId.compareTo(b.locId);
    });
    _tabularWeatherLastDbUpdate = DateTime.now();

    // Keep selection if it still exists, otherwise clear
    if (_tabularWeatherSelectedLocation != null) {
      final TabularWeatherLocation sel = _tabularWeatherSelectedLocation!;
      TabularWeatherLocation? next;
      for (final TabularWeatherLocation e in _tabularWeatherLocations) {
        if (e.stateId == sel.stateId && e.locId == sel.locId) {
          next = e;
          break;
        }
      }
      _tabularWeatherSelectedLocation = next;
    }

    _recomputeTabularWeatherForecasts();
    notifyListeners();
  }

  void updateTabularWeatherDatabaseBytes(List<int> bytes, {String? fileName}) {
    _tabularWeatherDbBytes = Uint8List.fromList(bytes);
    _tabularWeatherDbFileName = fileName;
    final TabularWeatherParsed parsed =
        TabularWeatherParser.parse(_tabularWeatherDbBytes!, fileName: fileName);
    updateTabularWeatherDatabase(parsed);
  }

  void beginTabularWeatherDbDownload({int? expectedBytes, String? fileName}) {
    _tabularWeatherDbDownloadInProgress = true;
    _tabularWeatherDbExpectedBytes = expectedBytes;
    _tabularWeatherDbReceivedBytes = 0;
    _tabularWeatherDbDownloadFileName = fileName;
    notifyListeners();
  }

  void updateTabularWeatherDbDownloadProgress(
      {int receivedBytes = 0, int? expectedBytes}) {
    if (receivedBytes >= 0) _tabularWeatherDbReceivedBytes = receivedBytes;
    if (expectedBytes != null && expectedBytes > 0) {
      _tabularWeatherDbExpectedBytes = expectedBytes;
    }
    _tabularWeatherDbDownloadInProgress = true;
    notifyListeners();
  }

  void finishTabularWeatherDbDownload() {
    _tabularWeatherDbDownloadInProgress = false;
    _tabularWeatherDbExpectedBytes = null;
    _tabularWeatherDbReceivedBytes = 0;
    _tabularWeatherDbDownloadFileName = null;
    notifyListeners();
  }

  bool reparseLastTabularWeatherDatabase() {
    final Uint8List? bytes = _tabularWeatherDbBytes;
    if (bytes == null || bytes.isEmpty) return false;
    final TabularWeatherParsed parsed =
        TabularWeatherParser.parse(bytes, fileName: _tabularWeatherDbFileName);
    updateTabularWeatherDatabase(parsed);
    return true;
  }

  void selectTabularWeatherLocation(TabularWeatherLocation? location) {
    _tabularWeatherSelectedLocation = location;
    _recomputeTabularWeatherForecasts();
    notifyListeners();
  }

  void recomputeTabularWeatherForecasts() {
    _recomputeTabularWeatherForecasts();
    notifyListeners();
  }

  void ingestTabularWeatherForecastAu({
    required int forecastType,
    required List<int> body,
  }) {
    if (forecastType < 0 || forecastType > 0xF) return;
    if (body.isEmpty) return;
    _tabularWeatherForecastBodiesByType[forecastType] = List<int>.from(body);
    _tabularWeatherLastForecastUpdate = DateTime.now();

    final TabularWeatherLocation? sel = _tabularWeatherSelectedLocation;
    if (sel == null) {
      return;
    }

    _tabularWeatherForecastByType[forecastType] =
        parseForecastFor(sel.stateId, sel.locId, body);
    notifyListeners();
  }

  void ingestWeatherAlert(WeatherAlertMessage alert) {
    _weatherAlerts.insert(0, alert);
    while (_weatherAlerts.length > 100) {
      _weatherAlerts.removeLast();
    }
    final DateTime now = DateTime.now();
    _activeWeatherAlertsByKey.removeWhere(
      (_, v) => v.receivedAt.add(const Duration(hours: 6)).isBefore(now),
    );
    final String key = '${alert.messageId}:${alert.languageId}';
    if (alert.stateBit == 1) {
      _activeWeatherAlertsByKey.remove(key);
    } else {
      _activeWeatherAlertsByKey[key] = alert;
    }
    notifyListeners();
  }

  void _recomputeTabularWeatherForecasts() {
    _tabularWeatherForecastByType.clear();
    final TabularWeatherLocation? sel = _tabularWeatherSelectedLocation;
    if (sel == null) return;

    for (final MapEntry<int, List<int>> e
        in _tabularWeatherForecastBodiesByType.entries) {
      _tabularWeatherForecastByType[e.key] =
          parseForecastFor(sel.stateId, sel.locId, e.value);
    }
  }
}

class WeatherAlertMessage {
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
  final int payloadLengthBytes;
  final String? alertText;
  final bool assembledFromSections;
  final List<int> rawAu;

  const WeatherAlertMessage({
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
    required this.payloadLengthBytes,
    required this.alertText,
    required this.assembledFromSections,
    required this.rawAu,
  });
}
