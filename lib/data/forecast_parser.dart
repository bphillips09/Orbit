import 'package:orbit/data/bit_buffer.dart';

class ForecastRecord {
  final int stateId;
  final int locId;
  final int eventCode;

  final int? tempMin;
  final int? tempCur;
  final int? tempMax;

  final int? cloud;
  final int? uv;
  final int? airq;
  final int? pollen;

  final Map<String, int> extras;

  const ForecastRecord({
    required this.stateId,
    required this.locId,
    required this.eventCode,
    this.tempMin,
    this.tempCur,
    this.tempMax,
    this.cloud,
    this.uv,
    this.airq,
    this.pollen,
    this.extras = const <String, int>{},
  });

  @override
  String toString() {
    return 'ForecastRecord(stateId: $stateId, locId: $locId, eventCode: $eventCode, tempMin: $tempMin, tempCur: $tempCur, tempMax: $tempMax, cloud: $cloud, uv: $uv, airq: $airq, pollen: $pollen, extras: $extras)';
  }
}

// Parse one forecast record for a specific state and location
ForecastRecord? parseForecastFor(
    int wantedState, int wantedLoc, List<int> body) {
  final BitBuffer b = BitBuffer(body);
  b.readBits(11);

  int curState = 0;
  int curLoc = 0;

  while (!b.hasError) {
    final int tag = b.readBits(2);
    if (b.hasError) break;

    switch (tag) {
      case 0:
        curLoc = (curLoc + 1) & 0x3F;
        break;
      case 1:
        curLoc = b.readBits(6);
        break;
      case 2:
        curState = b.readBits(7);
        curLoc = 1;
        break;
      case 3:
        curState = b.readBits(7);
        curLoc = b.readBits(6);
        break;
      default:
        return null;
    }
    if (b.hasError) break;

    if (curState == wantedState && curLoc == wantedLoc) {
      // Found the target record
      final int event = b.readBits(6);
      if (b.hasError) break;

      int? tempMin;
      int? tempCur;
      int? tempMax;
      int? cloud;
      int? uv;
      int? airq;
      int? pollen;
      final Map<String, int> extras = <String, int>{};

      // Presence-driven fields in order
      if (b.readBits(1) == 1) tempMin = b.readBits(8);
      if (b.readBits(1) == 1) tempCur = b.readBits(8);
      if (b.readBits(1) == 1) tempMax = b.readBits(8);

      if (b.readBits(1) == 1) {
        // 3-bit unknown
        extras['unk3bits'] = b.readBits(3);
      }

      if (b.readBits(1) == 1) {
        // 2-bit + 5-bit
        extras['ptype2'] = b.readBits(2);
        extras['amount5'] = b.readBits(5);
      }

      if (b.readBits(1) == 1) {
        // 4-bit + 4-bit
        extras['unk4a'] = b.readBits(4);
        extras['unk4b'] = b.readBits(4);
      }

      if (b.readBits(1) == 1) {
        // 3-bit
        extras['unk3c'] = b.readBits(3);
      }

      if (b.readBits(1) == 1) {
        cloud = b.readBits(3);
      }

      if (b.readBits(1) == 1) {
        final int val = b.readBits(3);
        if (val != 6) airq = val;
      }

      if (b.readBits(1) == 1) {
        final int val = b.readBits(4);
        if (val < 0xD) pollen = val;
      }

      // Skip tail optional blobs guarded by presence bits
      if (b.readBits(1) == 1) b.readBits(8);
      if (b.readBits(1) == 1) b.readBits(8);
      if (b.readBits(1) == 1) b.readBits(8);
      if (b.readBits(1) == 1) b.readBits(3);
      if (b.readBits(1) == 1) b.readBits(7);
      if (b.readBits(1) == 1) b.readBits(8);
      if (b.readBits(1) == 1) b.readBits(3);
      if (b.readBits(1) == 1) {
        final int v = b.readBits(3);
        if (v < 5) uv = v;
      }
      if (b.readBits(1) == 1) b.readBits(3);
      if (b.readBits(1) == 1) {
        final int v = b.readBits(3);
        if (v == 6) {
          // Unsupported?
        }
      }
      if (b.readBits(1) == 1) {
        final int v = b.readBits(4);
        if (v < 0xD) {
          pollen = v;
        }
      }
      if (b.readBits(1) == 1) {
        final int len = b.readBits(8);
        b.readBits(len * 8);
      }

      return ForecastRecord(
        stateId: wantedState,
        locId: wantedLoc,
        eventCode: event,
        tempMin: tempMin,
        tempCur: tempCur,
        tempMax: tempMax,
        cloud: cloud,
        uv: uv,
        airq: airq,
        pollen: pollen,
        extras: extras,
      );
    }
  }

  return null;
}
