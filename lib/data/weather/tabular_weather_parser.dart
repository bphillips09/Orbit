// Tabular Weather Parser
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/data/baudot.dart';

class TabularWeatherParsed {
  final int dbVersion;
  final int fileVersion;
  final int fileVersionBits;
  final List<TabularWeatherRegion> states;

  TabularWeatherParsed({
    required this.dbVersion,
    required this.fileVersion,
    required this.fileVersionBits,
    required this.states,
  });
}

class TabularWeatherRegion {
  final int id;
  final List<TabularWeatherEntry> entries;

  TabularWeatherRegion({required this.id, required this.entries});
}

class TabularWeatherEntry {
  final int index;
  final bool present;
  final bool flag;
  final double latDeg;
  final double lonDeg;

  final String name;
  final String icao;

  TabularWeatherEntry({
    required this.index,
    required this.present,
    required this.flag,
    required this.latDeg,
    required this.lonDeg,
    required this.name,
    required this.icao,
  });

  @override
  String toString() {
    return 'TabularWeatherEntry(index: $index, present: $present, flag: $flag, latDeg: $latDeg, lonDeg: $lonDeg, name: $name, icao: $icao)';
  }
}

class TabularWeatherParser {
  static TabularWeatherParsed parse(List<int> bytes, {String? fileName}) {
    final BitBuffer b = BitBuffer(bytes);

    int dbVersion = 0;
    int nameVersion = 0;
    if (fileName != null && fileName.length >= 5 && fileName[0] == 'U') {
      final String ab = fileName.substring(1, 3);
      final String cd = fileName.substring(3, 5);
      dbVersion = int.tryParse(ab) ?? 0;
      nameVersion = int.tryParse(cd) ?? 0;
    }

    // First 6 bits of file should match version
    final int fileVersionBits = b.readBits(6);

    final Map<int, TabularWeatherRegion> stateMap =
        <int, TabularWeatherRegion>{};

    while (!b.hasError) {
      final int tag2 = b.readBits(2);
      if (b.hasError) break;

      if (tag2 == 3) {
        // End of update
        break;
      }

      final int stateId = b.readBits(7);
      if (b.hasError) break;
      if (stateId == 0 || stateId > 0x60) {
        // Unknown/reserved, stop
        break;
      }
      final int entryIndex = b.readBits(6);
      if (b.hasError) break;

      bool present = false;
      bool flag = false;
      if (tag2 == 0) {
        present = false;
      } else if (tag2 == 1 || tag2 == 2) {
        present = true;
        final int bit = b.readBits(1);
        if (b.hasError) break;
        flag = bit == 1;
      } else {
        // Unexpected tag, stop
        break;
      }

      final int rawLat20 = b.readBits(20);
      final int rawLonDelta20 = b.readBits(20);
      if (b.hasError) break;
      // 13 bits of precision
      final double latDeg = rawLat20 / 8192.0;
      final double lonDeg = -50.0 - (rawLonDelta20 / 8192.0);

      final String name = BaudotDecoder.decodeFixed(b, 0x1F, 0x1F);
      final String icao = BaudotDecoder.decodeFixed(b, 5, 5);
      if (b.hasError) break;

      final TabularWeatherEntry entry = TabularWeatherEntry(
        index: entryIndex,
        present: present,
        flag: flag,
        latDeg: latDeg,
        lonDeg: lonDeg,
        name: name,
        icao: icao,
      );

      final TabularWeatherRegion state = stateMap[stateId] ??
          TabularWeatherRegion(id: stateId, entries: <TabularWeatherEntry>[]);
      // Replace any existing entry with same index
      final int existing =
          state.entries.indexWhere((e) => e.index == entryIndex);
      if (existing >= 0) {
        state.entries[existing] = entry;
      } else {
        state.entries.add(entry);
      }
      stateMap[stateId] = state;
    }

    final List<TabularWeatherRegion> states = stateMap.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return TabularWeatherParsed(
      dbVersion: dbVersion,
      fileVersion: nameVersion,
      fileVersionBits: fileVersionBits,
      states: states,
    );
  }
}
