import 'package:orbit/helpers.dart';
import 'package:orbit/logging.dart';

// SDTP Packet, represents a single SDTP packet
// SDTP = SXM Dynamic Transport Protocol
class SDTPPacket {
  final SDTPHeader header;
  final List<int> data;
  final int checksum;

  SDTPPacket({
    required this.header,
    required this.data,
    required this.checksum,
  });

  factory SDTPPacket.empty() {
    return SDTPPacket(header: SDTPHeader.empty(), data: [], checksum: 0);
  }

  // Factory constructor to create and validate an SDTP Packet.
  factory SDTPPacket.fromBytes(List<int> bytes, int lenMsb, int lenLsb) {
    if (bytes.length < 5) {
      logger.e('Invalid SDTP packet: Insufficient length.');
      return SDTPPacket.empty();
    }

    int packetLength = ((lenMsb << 8) | lenLsb) & 0xFFFF;

    // Validate packet length
    if (bytes.length != packetLength) {
      logger.e(
          'Invalid SDTP packet: Expected length $packetLength, got ${bytes.length}.');
      return SDTPPacket.empty();
    }

    // Validate checksum
    if (!_validateChecksum(bytes, packetLength)) {
      logger.e('Invalid SDTP packet: Checksum mismatch.');
      return SDTPPacket.empty();
    }

    // Parse the header
    SDTPHeader header = SDTPHeader.fromBytes(bytes.sublist(0, 4));

    // Parse the AU CRC or SDTP trailing checksum, depending on semantics
    // SDTP packet uses a 1-byte trailing checksum; AU (assembled later) has 4-byte CRC
    int checksum = bytes[bytes.length - 1];

    // Extract payload data (between header and trailing packet checksum)
    List<int> data = bytes.sublist(4, bytes.length - 1);

    return SDTPPacket(header: header, data: data, checksum: checksum);
  }

  // Validates the checksum for the given SDTP packet
  static bool _validateChecksum(List<int> dataPacket, int len) {
    // Calculate checksum by summing all bytes except the last one
    int checksum = 0;
    for (int x = 1; x < len - 1; x++) {
      checksum = (checksum + dataPacket[x]) & 0xFF;
    }

    // Compare computed checksum to the provided checksum (last byte)
    int providedChecksum = dataPacket[len - 1];
    return checksum == providedChecksum;
  }
}

// Represents the header of an SDTP Packet.
class SDTPHeader {
  final int sync; // Sync byte
  final int soa; // Start of Access Unit
  final int eoa; // End of Access Unit
  final int rfu; // Reserved for future use?
  final int psi; // Packet Sequence Index
  final int plpc; // Payload Length in Packet Count

  SDTPHeader({
    required this.sync,
    required this.soa,
    required this.eoa,
    required this.rfu,
    required this.psi,
    required this.plpc,
  });

  // Factory constructor to parse the header from raw bytes
  factory SDTPHeader.fromBytes(List<int> bytes) {
    if (bytes.length < 4) {
      logger.e('Invalid SDTP header: Insufficient data.');
      return SDTPHeader.empty();
    }

    int sync = bytes[0];
    int soa = (bytes[1] >> 7) & 0x1;
    int eoa = (bytes[1] >> 6) & 0x1;
    int rfu = (bytes[1] >> 4) & 0x3;
    int psi = ((bytes[1] & 0xF) << 6) | (bytes[2] >> 2);
    int plpc = bitCombine((bytes[2] & 0x3), bytes[3]);

    return SDTPHeader(
      sync: sync,
      soa: soa,
      eoa: eoa,
      rfu: rfu,
      psi: psi,
      plpc: plpc,
    );
  }

  factory SDTPHeader.empty() {
    return SDTPHeader(sync: 0, soa: 0, eoa: 0, rfu: 0, psi: 0, plpc: 0);
  }

  @override
  String toString() {
    return 'SDTPHeader(sync: $sync, soa: $soa, eoa: $eoa, rfu: $rfu, psi: $psi, plpc: $plpc)';
  }
}
