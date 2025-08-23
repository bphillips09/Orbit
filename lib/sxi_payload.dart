// SXi payload for the SXi protocol
import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_indications.dart';

abstract class SXiPayload {
  int opcodeMsb;
  int opcodeLsb;
  int transactionID;
  static int nextIndex = 16;
  int get opcode {
    return bitCombine(opcodeMsb, opcodeLsb);
  }

  // Map of opcode to constructor for the SXi indications
  static final Map indications = {
    0x8020: (bytes) => SXiConfigureModuleIndication.fromBytes(bytes),
    0x8021: (bytes) => SXiPowerModeIndication.fromBytes(bytes),
    0x8060: (bytes) => SXiTimeIndication.fromBytes(bytes),
    0x8080: (bytes) => SXiEventIndication.fromBytes(bytes),
    0x80f0: (bytes) => SXiIPAuthenticationIndication.fromBytes(bytes),
    0x80f1: (bytes) => SXiAuthenticationIndication.fromBytes(bytes),
    0x80a0: (bytes) => SXiStatusIndication.fromBytes(bytes),
    0x80c0: (bytes) => SXiDisplayAdvisoryIndication.fromBytes(bytes),
    0x80c1: (bytes) => SXiSubscriptionStatusIndication.fromBytes(bytes),
    0x8200: (bytes) => SXiBrowseChannelIndication.fromBytes(bytes),
    0x8201: (bytes) => SXiCategoryInfoIndication.fromBytes(bytes),
    0x8280: (bytes) => SXiSelectChannelIndication.fromBytes(bytes),
    0x8281: (bytes) => SXiChannelInfoIndication.fromBytes(bytes),
    0x8300: (bytes) => SXiMetadataIndication.fromBytes(bytes),
    0x8301: (bytes) => SXiChannelMetadataIndication.fromBytes(bytes),
    0x8302: (bytes) => SXiGlobalMetadataIndication.fromBytes(bytes),
    0x8303: (bytes) => SXiLookAheadMetadataIndication.fromBytes(bytes),
    0x8304: (bytes) => SXiSeekIndication.fromBytes(bytes),
    0x8402: (bytes) => SXiInstantReplayPlaybackInfoIndication.fromBytes(bytes),
    0x8403: (bytes) =>
        SXiInstantReplayPlaybackMetadataIndication.fromBytes(bytes),
    0x8404: (bytes) => SXiInstantReplayRecordInfoIndication.fromBytes(bytes),
    0x8405: (bytes) =>
        SXiInstantReplayRecordMetadataIndication.fromBytes(bytes),
    0x8420: (bytes) => SXiBulletinStatusIndication.fromBytes(bytes),
    0x8421: (bytes) => SXiFlashIndication.fromBytes(bytes),
    0x8422: (bytes) => SXiContentBufferedIndication.fromBytes(bytes),
    0x8442: (bytes) => SXiRecordTrackMetadataIndication.fromBytes(bytes),
    0x8500: (bytes) => SXiDataServiceStatusIndication.fromBytes(bytes),
    0x8510: (bytes) => SXiDataPacketIndication.fromBytes(bytes),
    0x8e84: (bytes) => SXiFirmwareEraseIndication.fromBytes(bytes),
    0x8ed0: (bytes) => SXiPackageIndication.fromBytes(bytes),
    0xc26f: (bytes) => SXiErrorIndication.fromBytes(bytes),
  };

  SXiPayload(this.opcodeMsb, this.opcodeLsb, this.transactionID);

  // Convert the payload to a byte list
  List<int> toBytes() {
    return [
      opcodeMsb,
      opcodeLsb,
      transactionID,
      ...getParameters(),
    ];
  }

  List<int> getParameters();

  static List<int> parseNullTerminatedString(List<int> frame, int startIndex) {
    List<int> result = [];
    for (int i = startIndex; i < frame.length; i++) {
      if (frame[i] == 0x00) break;
      result.add(frame[i]);
    }
    return result;
  }

  static List<int> parseNextString(List<int> frame, int startIndex) {
    final result = SXiPayload.parseNullTerminatedString(frame, startIndex);
    nextIndex = startIndex + result.length + 1;
    return result;
  }

  // Parse length-prefixed data in-line
  static List<int> parseLengthPrefixedData(List<int> frame, int startIndex) {
    if (startIndex >= frame.length) {
      nextIndex = startIndex;
      return [];
    }

    int length = frame[startIndex];
    int dataStart = startIndex + 1;

    if (dataStart + length > frame.length) {
      // Not enough data, return what we can
      nextIndex = frame.length;
      return frame.length > dataStart ? frame.sublist(dataStart) : [];
    }

    nextIndex = dataStart + length;
    return frame.sublist(dataStart, nextIndex);
  }

  // Parse the bytes into a SXi payload
  static SXiPayload fromBytes(List<int> bytes) {
    // Heartbeat payloads are always 2 bytes
    if (bytes.length == 2) {
      return HeartbeatPayload(0, 0, 0, List.empty());
    }

    // Get the constructor for the opcode
    var constructor = indications[bitCombine(bytes[0], bytes[1])];
    if (constructor != null) {
      return constructor(bytes);
    }

    // If no constructor is found, it's a generic payload
    return GenericPayload.fromBytes(bytes);
  }

  @override
  String toString() {
    return '$runtimeType: ${getParameters()}';
  }
}

// Heartbeat payload
class HeartbeatPayload extends SXiPayload {
  final List<int> parameters;

  HeartbeatPayload(
      super.opcodeMsb, super.opcodeLsb, super.transactionID, this.parameters);

  HeartbeatPayload.fromBytes(List<int> bytes)
      : parameters = List.empty(),
        super(bytes[0], bytes[1], bytes[2]);

  @override
  List<int> getParameters() => parameters;
}

// Generic payload
class GenericPayload extends SXiPayload {
  final List<int> parameters;

  GenericPayload(
      super.opcodeMsb, super.opcodeLsb, super.transactionID, this.parameters);

  GenericPayload.fromBytes(List<int> bytes)
      : parameters = bytes.sublist(3),
        super(bytes[0], bytes[1], bytes[2]);

  @override
  List<int> getParameters() => parameters;
}
