import 'package:orbit/helpers.dart';

// Signal Quality, represents a channel's signal quality
class SignalQuality {
  final int signalStrength;
  final int tunerStatus;
  final int ensALockStatus;
  final int ensBLockStatus;
  final int berS1;
  final int berS2;
  final int berT;

  SignalQuality({
    required this.signalStrength,
    required this.tunerStatus,
    required this.ensALockStatus,
    required this.ensBLockStatus,
    required this.berS1,
    required this.berS2,
    required this.berT,
  });

  factory SignalQuality.fromBytes(List<int> bytes) {
    // Helper function to safely get a byte at index, return 0 if out of bounds
    int getByte(int index) => index < bytes.length ? bytes[index] : 0;

    // Helper function to safely combine two bytes into a 16-bit value
    int getCombined(int msbIndex, int lsbIndex) {
      final msb = getByte(msbIndex);
      final lsb = getByte(lsbIndex);
      return bitCombine(msb, lsb);
    }

    return SignalQuality(
      signalStrength: getByte(0),
      tunerStatus: getByte(1),
      ensALockStatus: getByte(2),
      ensBLockStatus: getByte(3),
      berS1: getCombined(4, 5),
      berS2: getCombined(6, 7),
      berT: getCombined(8, 9),
    );
  }

  String get tunerStatusHex =>
      '0x${tunerStatus.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String get tunerStatusFlags {
    if (tunerStatus == 0) return '';

    List<String> flags = [];
    if (tunerStatus & 0x20 != 0) flags.add('IF AGC Active');
    if (tunerStatus & 0x10 != 0) flags.add('RF AGC Active');
    if (tunerStatus & 0x08 != 0) flags.add('Antenna Over-Range');
    if (tunerStatus & 0x04 != 0) flags.add('Antenna Under-Range');
    if (tunerStatus & 0x02 != 0) flags.add('Antenna Detected');
    if (tunerStatus & 0x01 != 0) flags.add('PLL Lock');

    return flags.isEmpty ? '' : flags.join(', ');
  }

  String get ensALockStatusHex =>
      '0x${ensALockStatus.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String get ensALockStatusFlags {
    if (ensALockStatus == 0) return '';

    List<String> flags = [];
    if (ensALockStatus & 0x20 != 0) flags.add('Satellite 1 TDM Lock');
    if (ensALockStatus & 0x10 != 0) flags.add('Satellite 1 QPSK Lock');
    if (ensALockStatus & 0x08 != 0) flags.add('Satellite 2 TDM Lock');
    if (ensALockStatus & 0x04 != 0) flags.add('Satellite 2 QPSK Lock');
    if (ensALockStatus & 0x02 != 0) flags.add('Terrestrial TDM Lock');
    if (ensALockStatus & 0x01 != 0) flags.add('Terrestrial QPSK Lock');

    return flags.isEmpty ? '' : flags.join(', ');
  }

  String get ensBLockStatusHex =>
      '0x${ensBLockStatus.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String get ensBLockStatusFlags {
    if (ensBLockStatus == 0) return '';

    List<String> flags = [];
    if (ensBLockStatus & 0x20 != 0) flags.add('Satellite 1 TDM Lock');
    if (ensBLockStatus & 0x10 != 0) flags.add('Satellite 1 QPSK Lock');
    if (ensBLockStatus & 0x08 != 0) flags.add('Satellite 2 TDM Lock');
    if (ensBLockStatus & 0x04 != 0) flags.add('Satellite 2 QPSK Lock');
    if (ensBLockStatus & 0x02 != 0) flags.add('Terrestrial TDM Lock');
    if (ensBLockStatus & 0x01 != 0) flags.add('Terrestrial QPSK Lock');

    return flags.isEmpty ? '' : flags.join(', ');
  }

  // BER values are percentages
  String get berS1Percent => '${(berS1 / 65535.0 * 100).toStringAsFixed(3)}%';
  String get berS2Percent => '${(berS2 / 65535.0 * 100).toStringAsFixed(3)}%';
  String get berTPercent => '${(berT / 65535.0 * 100).toStringAsFixed(3)}%';

  @override
  String toString() {
    return '''SignalQuality {
  Signal Strength:      $signalStrength
  Tuner Status:         $tunerStatusHex$tunerStatusFlags
  ENSA Lock Status:     $ensALockStatusHex$ensALockStatusFlags
  ENSB Lock Status:     $ensBLockStatusHex$ensBLockStatusFlags
  SAT1 BER:             $berS1Percent
  SAT2 BER:             $berS2Percent
  TERR BER:             $berTPercent
}''';
  }
}

class OverlaySignalQuality {
  final int receiverState;
  final int oberS1A;
  final int oberS2A;
  final int oberTA;
  final int oberS1B;
  final int oberS2B;
  final int oberTB;

  OverlaySignalQuality({
    required this.receiverState,
    required this.oberS1A,
    required this.oberS2A,
    required this.oberTA,
    required this.oberS1B,
    required this.oberS2B,
    required this.oberTB,
  });

  factory OverlaySignalQuality.fromBytes(List<int> bytes) {
    // Helper function to safely get a byte at index, return 0 if out of bounds
    int getByte(int index) => index < bytes.length ? bytes[index] : 0;

    // Helper function to safely combine two bytes into a 16-bit value
    int getCombined(int msbIndex, int lsbIndex) {
      final msb = getByte(msbIndex);
      final lsb = getByte(lsbIndex);
      return bitCombine(msb, lsb);
    }

    return OverlaySignalQuality(
      receiverState: getByte(0),
      oberS1A: getCombined(1, 2),
      oberS2A: getCombined(3, 4),
      oberTA: getCombined(5, 6),
      oberS1B: getCombined(7, 8),
      oberS2B: getCombined(9, 10),
      oberTB: getCombined(11, 12),
    );
  }

  // Helper methods for proper formatting based on analysis
  String get receiverStateHex =>
      '0x${receiverState.toRadixString(16).padLeft(2, '0').toUpperCase()}';

  String get receiverStateFlags {
    if (receiverState == 0) return '';

    List<String> flags = [];
    if (receiverState & 0x80 != 0) flags.add('Pipe Lock A');
    if (receiverState & 0x40 != 0) flags.add('Satellite 1A OTDM');
    if (receiverState & 0x20 != 0) flags.add('Satellite 2A OTDM');
    if (receiverState & 0x10 != 0) flags.add('Terrestrial A OTDM');
    if (receiverState & 0x08 != 0) flags.add('Pipe Lock B');
    if (receiverState & 0x04 != 0) flags.add('Satellite 1B OTDM');
    if (receiverState & 0x02 != 0) flags.add('Satellite 2B OTDM');
    if (receiverState & 0x01 != 0) flags.add('Terrestrial B OTDM');

    return flags.isEmpty ? '' : flags.join(', ');
  }

  // OBER values are percentages
  String get oberS1APercent =>
      '${(oberS1A / 65535.0 * 100).toStringAsFixed(1)}%';
  String get oberS2APercent =>
      '${(oberS2A / 65535.0 * 100).toStringAsFixed(1)}%';
  String get oberTAPercent => '${(oberTA / 65535.0 * 100).toStringAsFixed(1)}%';
  String get oberS1BPercent =>
      '${(oberS1B / 65535.0 * 100).toStringAsFixed(1)}%';
  String get oberS2BPercent =>
      '${(oberS2B / 65535.0 * 100).toStringAsFixed(1)}%';
  String get oberTBPercent => '${(oberTB / 65535.0 * 100).toStringAsFixed(1)}%';

  @override
  String toString() {
    return '''OverlaySignalQuality {
  Overlay Receiver Status:  $receiverStateHex$receiverStateFlags
  OSAT1A BER:               $oberS1APercent
  OSAT2A BER:               $oberS2APercent
  OTA BER:                  $oberTAPercent
  OSAT1B BER:               $oberS1BPercent
  OSAT2B BER:               $oberS2BPercent
  OTB BER:                  $oberTBPercent
}''';
  }
}
