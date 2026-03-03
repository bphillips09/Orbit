// Tabular Weather Location
import 'dart:collection';
import 'package:orbit/data/weather/tabular_weather_parser.dart';

class TabularWeatherLocation {
  final int stateId;
  final int locId;
  final bool present;
  final bool flag;

  final double latDeg;
  final double lonDeg;

  final String name;
  final String icao;

  const TabularWeatherLocation({
    required this.stateId,
    required this.locId,
    required this.present,
    required this.flag,
    required this.latDeg,
    required this.lonDeg,
    required this.name,
    required this.icao,
  });

  String get displayName => name.trim();
  String get stationId => icao.trim();

  @override
  String toString() {
    return 'TabularWeatherLocation(stateId: $stateId, locId: $locId, present: $present, flag: $flag, latDeg: $latDeg, lonDeg: $lonDeg, name: $name, icao: $icao)';
  }
}

List<TabularWeatherLocation> tabularWeatherFlattenLocations(
    TabularWeatherParsed parsed) {
  final List<TabularWeatherLocation> out = <TabularWeatherLocation>[];
  for (final TabularWeatherRegion s in parsed.states) {
    for (final TabularWeatherEntry e in s.entries) {
      out.add(
        TabularWeatherLocation(
          stateId: s.id,
          locId: e.index,
          present: e.present,
          flag: e.flag,
          latDeg: e.latDeg,
          lonDeg: e.lonDeg,
          name: e.name,
          icao: e.icao,
        ),
      );
    }
  }
  return out;
}

// Simple search helper for location queries
List<TabularWeatherLocation> tabularWeatherSearchLocations(
  List<TabularWeatherLocation> all,
  String query, {
  int limit = 25,
}) {
  final String q = query.trim();
  if (q.isEmpty) return const <TabularWeatherLocation>[];

  final String qLower = q.toLowerCase();
  final List<_TabularWeatherSearchHit> hits = <_TabularWeatherSearchHit>[];
  for (final TabularWeatherLocation loc in all) {
    if (!loc.present) continue;

    final String id = loc.stationId.toLowerCase();
    final String name = loc.displayName.toLowerCase();

    int rank = 1000;
    if (id.isNotEmpty && id == qLower) {
      rank = 0; // Exact station ID
    } else if (id.isNotEmpty && id.startsWith(qLower)) {
      rank = 1; // Station ID prefix
    } else if (name.startsWith(qLower)) {
      rank = 2; // Name prefix
    } else if (name.contains(qLower)) {
      rank = 3; // Name substring
    }

    if (rank < 1000) {
      hits.add(_TabularWeatherSearchHit(location: loc, rank: rank));
    }
  }

  hits.sort((a, b) {
    final int c1 = a.rank.compareTo(b.rank);
    if (c1 != 0) return c1;

    final int c2 = a.location.displayName.length.compareTo(
      b.location.displayName.length,
    );
    if (c2 != 0) return c2;

    return a.location.displayName
        .toLowerCase()
        .compareTo(b.location.displayName.toLowerCase());
  });

  final Iterable<TabularWeatherLocation> out =
      hits.take(limit).map((h) => h.location);
  return UnmodifiableListView<TabularWeatherLocation>(out);
}

class _TabularWeatherSearchHit {
  final TabularWeatherLocation location;
  final int rank;

  const _TabularWeatherSearchHit({
    required this.location,
    required this.rank,
  });
}
