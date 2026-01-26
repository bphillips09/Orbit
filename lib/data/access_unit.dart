import 'package:orbit/data/sdtp.dart';
import 'package:orbit/logging.dart';

// Access Unit (AU), assembled from SDTP packets
class AccessUnit {
  final List<int> header;
  final List<int> data;
  final int crc;

  AccessUnit({
    required this.header,
    required this.data,
    required this.crc,
  });

  List<int> getHeaderAndData() {
    return header + data;
  }

  factory AccessUnit.fromBytes(List<int> bytes) {
    final List<int> header = bytes.sublist(0, 4);
    final List<int> auData = bytes.sublist(4, bytes.length - 4);
    final int crc = (bytes[bytes.length - 4] << 24) |
        (bytes[bytes.length - 3] << 16) |
        (bytes[bytes.length - 2] << 8) |
        bytes[bytes.length - 1];

    return AccessUnit(header: header, data: auData, crc: crc);
  }

  factory AccessUnit.fromSDTPPackets(List<SDTPPacket> packets) {
    if (packets.isEmpty) {
      throw ArgumentError('Cannot create an Access Unit from empty packets.');
    }

    // Concatenate packet payloads defensively
    final List<int> concatenated = <int>[];
    for (final SDTPPacket packet in packets) {
      if (packet.data.isNotEmpty) {
        concatenated.addAll(packet.data);
      }
    }

    // Minimum AU size: 4 header bytes + 4 CRC bytes
    if (concatenated.length < 8) {
      logger.e('Access Unit too short: ${concatenated.length} bytes');
      return AccessUnit(header: [], data: [], crc: 0);
    }

    // Slice header/data/CRC safely
    final List<int> header = concatenated.sublist(0, 4);
    final int crcStart = concatenated.length - 4;
    final int crc = (concatenated[crcStart] << 24) |
        (concatenated[crcStart + 1] << 16) |
        (concatenated[crcStart + 2] << 8) |
        concatenated[crcStart + 3];

    // If there is no payload between header and CRC, return empty data
    final List<int> auData =
        crcStart > 4 ? concatenated.sublist(4, crcStart) : const <int>[];

    return AccessUnit(header: header, data: auData, crc: crc);
  }

  List<int> toBytes() {
    return header + data + [crc];
  }
}

class AccessUnitGroup {
  final int sid;
  final int pid;
  final List<List<int>?> units = [];
  int totalAUs;
  int receivedAUs = 0;

  AccessUnitGroup(
      {required this.sid, required this.pid, required this.totalAUs});

  bool addUnit(int index, List<int> auData) {
    if (units.length <= index) {
      units.length = index + 1; // Expand list if needed
    }
    if (units[index] == null) {
      units[index] = auData;
      receivedAUs++;
    }
    return receivedAUs == totalAUs;
  }

  List<int> assemble() {
    List<int> assembled = [];
    for (var au in units) {
      if (au != null) {
        assembled.addAll(au);
      }
    }
    return assembled;
  }
}
