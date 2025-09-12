import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/data/baudot.dart';

class WxTabParsed {
  final int dbVersion;
  final int fileVersion;
  final int fileVersionBits;
  final List<WxState> states;

  WxTabParsed({
    required this.dbVersion,
    required this.fileVersion,
    required this.fileVersionBits,
    required this.states,
  });
}

class WxState {
  final int id;
  final List<WxEntry> entries;

  WxState({required this.id, required this.entries});
}

class WxEntry {
  final int index;
  final bool present;
  final bool flag;
  final int rawA20;
  final int rawB20;
  final double valueA;
  final double valueB;
  final String longText;
  final String shortText;

  WxEntry({
    required this.index,
    required this.present,
    required this.flag,
    required this.rawA20,
    required this.rawB20,
    required this.valueA,
    required this.valueB,
    required this.longText,
    required this.shortText,
  });

  @override
  String toString() {
    return 'WxEntry(index: $index, present: $present, flag: $flag, rawA20: $rawA20, rawB20: $rawB20, valueA: $valueA, valueB: $valueB, longText: $longText, shortText: $shortText)';
  }
}

class WxTabParser {
  static WxTabParsed parse(List<int> bytes, {String? fileName}) {
    final BitBuffer b = BitBuffer(bytes);

    // Infer DB and file version from name
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

    final Map<int, WxState> stateMap = <int, WxState>{};

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
        // Unknown/reserved, stop to avoid desync
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

      // Two 20-bit fixed point numbers
      final int rawA = b.readBits(20);
      final int rawB = b.readBits(20);
      if (b.hasError) break;
      final double valueA = rawA / 8192.0;
      final double valueB = rawB / 8192.0;

      // Two Baudot strings
      final String longText = BaudotDecoder.decodeFixed(b, 0x1F, 0x1F);
      final String shortText = BaudotDecoder.decodeFixed(b, 5, 5);
      if (b.hasError) break;

      final WxEntry entry = WxEntry(
        index: entryIndex,
        present: present,
        flag: flag,
        rawA20: rawA,
        rawB20: rawB,
        valueA: valueA,
        valueB: valueB,
        longText: longText,
        shortText: shortText,
      );

      final WxState state =
          stateMap[stateId] ?? WxState(id: stateId, entries: <WxEntry>[]);
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

    final List<WxState> states = stateMap.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return WxTabParsed(
      dbVersion: dbVersion,
      fileVersion: nameVersion,
      fileVersionBits: fileVersionBits,
      states: states,
    );
  }
}
