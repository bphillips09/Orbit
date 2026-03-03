// Tabular Weather Forecast Parser
import 'package:orbit/data/bit_buffer.dart';

class ForecastRecord {
  final int stateId;
  final int locId;
  final int eventCode;

  final double? tempMinF;
  final double? tempCurF;
  final double? tempMaxF;
  final int? pop;
  final int? ptype;
  final int? amount;
  final int? wspeed;
  final int? wdir;
  final int? humidity;
  final int? cloud;
  final int? uv;
  final int? airq;
  final int? pollen;

  const ForecastRecord({
    required this.stateId,
    required this.locId,
    required this.eventCode,
    this.tempMinF,
    this.tempCurF,
    this.tempMaxF,
    this.pop,
    this.ptype,
    this.amount,
    this.wspeed,
    this.wdir,
    this.humidity,
    this.cloud,
    this.uv,
    this.airq,
    this.pollen,
  });

  @override
  String toString() {
    return 'ForecastRecord(stateId: $stateId, locId: $locId, eventCode: $eventCode, tempMinF: $tempMinF, tempCurF: $tempCurF, tempMaxF: $tempMaxF, pop: $pop, ptype: $ptype, amount: $amount, wspeed: $wspeed, wdir: $wdir, humidity: $humidity, cloud: $cloud, uv: $uv, airq: $airq, pollen: $pollen)';
  }
}

double _decodeTempF(int raw) => raw.toDouble();

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

    // Always read the 6-bit event code regardless of match
    final int event = b.readBits(6);
    if (b.hasError) break;

    final bool isMatch = curState == wantedState && curLoc == wantedLoc;
    if (isMatch) {
      double? tempMinF;
      double? tempCurF;
      double? tempMaxF;
      int? pop;
      int? ptype;
      int? amount;
      int? wspeed;
      int? wdir;
      int? humidity;
      int? cloud;
      int? uv;
      int? airq;
      int? pollen;

      if (b.readBits(1) == 1) tempCurF = _decodeTempF(b.readBits(8));
      if (b.readBits(1) == 1) tempMaxF = _decodeTempF(b.readBits(8));
      if (b.readBits(1) == 1) tempMinF = _decodeTempF(b.readBits(8));

      if (b.readBits(1) == 1) {
        pop = b.readBits(3);
      }
      if (b.readBits(1) == 1) {
        ptype = b.readBits(2);
        amount = b.readBits(5);
      }
      if (b.readBits(1) == 1) {
        wdir = b.readBits(4);
        wspeed = b.readBits(4);
      }
      if (b.readBits(1) == 1) {
        humidity = b.readBits(3);
      }
      if (b.readBits(1) == 1) {
        final int val = b.readBits(3);
        if (val <= 4) cloud = val;
      }
      if (b.readBits(1) == 1) {
        uv = b.readBits(3);
      }
      if (b.readBits(1) == 1) {
        final int val = b.readBits(3);
        if (val != 6) airq = val;
      }
      if (b.readBits(1) == 1) {
        final int val = b.readBits(4);
        if (val < 0xD) pollen = val;
      }

      return ForecastRecord(
        stateId: wantedState,
        locId: wantedLoc,
        eventCode: event,
        tempMinF: tempMinF,
        tempCurF: tempCurF,
        tempMaxF: tempMaxF,
        pop: pop,
        ptype: ptype,
        amount: amount,
        wspeed: wspeed,
        wdir: wdir,
        humidity: humidity,
        cloud: cloud,
        uv: uv,
        airq: airq,
        pollen: pollen,
      );
    }

    // Consume the rest of this record to stay in sync
    if (b.readBits(1) == 1) b.readBits(8);
    if (b.readBits(1) == 1) b.readBits(8);
    if (b.readBits(1) == 1) b.readBits(8);
    if (b.readBits(1) == 1) b.readBits(3);
    if (b.readBits(1) == 1) {
      b.readBits(2);
      b.readBits(5);
    }
    if (b.readBits(1) == 1) {
      b.readBits(4);
      b.readBits(4);
    }
    if (b.readBits(1) == 1) b.readBits(3); // Humidity bucket
    if (b.readBits(1) == 1) b.readBits(3); // Cloud bucket
    if (b.readBits(1) == 1) b.readBits(3); // UV bucket
    if (b.readBits(1) == 1) b.readBits(3); // Air quality bucket
    if (b.readBits(1) == 1) b.readBits(4); // Pollen bucket
    if (b.readBits(1) == 1) {
      final int len = b.readBits(8);
      b.readBits((len * 8) + 8);
    }
  }

  return null;
}
