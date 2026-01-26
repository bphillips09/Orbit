import 'package:orbit/data/access_unit.dart';
import 'package:orbit/data/data_handler.dart';
import 'package:orbit/data/bit_buffer.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/crc.dart';

class FuelHandler extends DSIHandler {
  final Map<int, Map<int, AccessUnitGroup>> auGroups = {};
  final Map<int, FuelStationPrices> _stationById = {};

  FuelHandler(SXiLayer sxiLayer)
      : super(DataServiceIdentifier.fuelPrices, sxiLayer);

  @override
  void onAccessUnitComplete(AccessUnit unit) {
    final List<int> auBytes = unit.getHeaderAndData();
    final BitBuffer b = BitBuffer(auBytes);
    final int pvn = b.readBits(4);
    final int carid = b.readBits(3);

    if (pvn != 1) {
      logger.w('FuelHandler: Unsupported PVN: $pvn');
      return;
    }

    try {
      if (!CRC32.check(auBytes, unit.crc)) {
        logger.e('FuelHandler: CRC check failed for AU (CARID $carid)');
        return;
      }
    } catch (_) {
      logger.e('FuelHandler: CRC check failed (exception)');
      return;
    }

    switch (carid) {
      case 0:
        logger.d('FuelHandler: Prices AU received');
        _handlePrices(b);
        break;
      case 1:
        logger.d('FuelHandler: Grid RFD add');
        break;
      case 2:
        logger.d('FuelHandler: Text AU received');
        break;
      case 3:
        logger.d('FuelHandler: RFD Metadata AU');
        break;
      default:
        logger.w('FuelHandler: Unknown CARID $carid');
        break;
    }
  }

  void _handlePrices(BitBuffer b) {
    final int txtVersion = b.readBits(8);
    final int fsRegion = b.readBits(11);
    if (b.hasError) {
      logger
          .e('FuelHandler: Failed to read text version or fuel station region');
      return;
    }
    logger.d(
        'FuelHandler: Fuel station region: $fsRegion, Text version: $txtVersion');

    int totalAus = 1;
    int auIndex = 0;
    if (b.readBits(1) == 1) {
      final int width = b.readBits(4) + 1;
      totalAus = b.readBits(width) + 1;
      auIndex = b.readBits(width);
    }

    final int fsSize = b.readBits(4);
    if (b.hasError) {
      logger.e('FuelHandler: Fuel Price AU header read error');
      return;
    }

    if (fsSize >= 14) {
      logger.e('FuelHandler: Unsupported bit width: $fsSize');
      return;
    }

    final List<_FuelTypeDef> defs = <_FuelTypeDef>[];
    while (true) {
      final int typeIndex = b.readBits(6);
      final int unitMode = b.readBits(2);
      final int baseOffset = b.readBits(12);
      final int valueWidth = b.readBits(4) + 2;
      defs.add(_FuelTypeDef(
        index: typeIndex,
        unitMode: unitMode,
        baseOffset: baseOffset,
        valueWidth: valueWidth,
      ));

      final int more = b.readBits(1);

      if (b.hasError) {
        logger.e('FuelHandler: Fuel Price AU header parse failed');
        return;
      }
      if (more == 0) break;
    }

    if (defs.isEmpty) {
      logger.w('FuelHandler: No fuel type definitions present');
      return;
    }

    int currentFsuid = 0;
    int processedStations = 0;

    while (b.remainingBytes > 0 && !b.hasError) {
      int increment = -1;
      for (int k = 1; k <= 6; k++) {
        final int bit = b.readBits(1);
        if (b.hasError) break;
        if (bit == 1) {
          increment = k;
          break;
        }
      }
      if (b.hasError) break;

      if (increment == -1) {
        currentFsuid = b.readBits(fsSize);
        if (b.hasError) break;
      } else {
        currentFsuid += increment;
      }

      final int fsuidFull =
          ((fsRegion & 0xFFFF) << 16) | (currentFsuid & 0xFFFF);

      final Map<int, FuelPriceEntry> entries = <int, FuelPriceEntry>{};
      bool anyPresent = false;

      for (int i = 0; i < defs.length; i++) {
        final _FuelTypeDef d = defs[i];
        final int present = b.readBits(1);
        if (b.hasError) break;
        if (present != 1) {
          entries[d.index] = FuelPriceEntry(
            fuelType: d.index,
            unitMode: d.unitMode,
            priceMinor: null,
            ageCode: 0xF,
            outOfFuel: false,
            display: 'Unknown',
          );
          continue;
        }

        final int ageCode = b.readBits(2) & 0x3;
        final int priceBits = b.readBits(d.valueWidth);
        if (b.hasError) {
          break;
        }
        final int sentinel = (1 << d.valueWidth) - 1;
        bool outOfFuel = false;
        int? priceMinor;
        String display;

        if (priceBits == sentinel) {
          outOfFuel = true;
          display = 'Out of Fuel';
        } else {
          final int raw = priceBits + d.baseOffset;
          if (d.unitMode == 3) {
            priceMinor = raw; // Thousandths
            final int major = priceMinor ~/ 1000;
            final int frac = priceMinor % 1000;
            display = '$major.${frac.toString().padLeft(3, '0')}';
          } else {
            final int scaled = (d.unitMode == 2) ? (raw * 10) : raw;
            priceMinor = scaled; // Hundredths
            final int major = priceMinor ~/ 100;
            final int frac = priceMinor % 100;
            display = '$major.${frac.toString().padLeft(2, '0')}';
          }
        }

        entries[d.index] = FuelPriceEntry(
          fuelType: d.index,
          unitMode: d.unitMode,
          priceMinor: priceMinor,
          ageCode: ageCode,
          outOfFuel: outOfFuel,
          display: display,
        );
        anyPresent = true;
      }

      if (b.hasError) {
        logger
            .e('FuelHandler: Failed to read station prices (bitstream ended)');
        break;
      }

      if (anyPresent) {
        _stationById[fsuidFull] = FuelStationPrices(
          fsuid: fsuidFull,
          fsRegion: fsRegion,
          txtVersion: txtVersion,
          timestamp: DateTime.now(),
          entries: entries,
        );
        processedStations += 1;
      }
    }

    logger.i(
        'FuelHandler: Processed $processedStations station(s) in fuel station region $fsRegion (AU $auIndex/${totalAus - 1})');
  }

  Map<int, FuelStationPrices> getSnapshot() =>
      Map<int, FuelStationPrices>.from(_stationById);
}

class _FuelTypeDef {
  final int index;
  final int unitMode;
  final int baseOffset;
  final int valueWidth;
  _FuelTypeDef({
    required this.index,
    required this.unitMode,
    required this.baseOffset,
    required this.valueWidth,
  });
}

class FuelPriceEntry {
  final int fuelType;
  final int unitMode;
  final int? priceMinor;
  final int ageCode;
  final bool outOfFuel;
  final String display;

  const FuelPriceEntry({
    required this.fuelType,
    required this.unitMode,
    required this.priceMinor,
    required this.ageCode,
    required this.outOfFuel,
    required this.display,
  });
}

class FuelStationPrices {
  final int fsuid;
  final int fsRegion;
  final int txtVersion;
  final DateTime timestamp;
  final Map<int, FuelPriceEntry> entries;

  const FuelStationPrices({
    required this.fsuid,
    required this.fsRegion,
    required this.txtVersion,
    required this.timestamp,
    required this.entries,
  });
}
