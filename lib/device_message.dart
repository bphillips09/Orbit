// Device message class
import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_indications.dart';
import 'package:orbit/sxi_payload.dart';

class DeviceMessage {
  final int sequence;
  final PayloadType payloadType;
  final SXiPayload payload;
  late final int payloadLength;
  late final int checksum;
  List<int>? _cachedPayloadBytes;
  List<int> get payloadAsBytes {
    return _cachedPayloadBytes ??= payload.toBytes();
  }

  DeviceMessage(this.sequence, this.payloadType, this.payload) {
    _cachedPayloadBytes = payload.toBytes();
    payloadLength = _cachedPayloadBytes!.length;
    checksum = calculateChecksum();
  }

  // Create a device message from a byte frame
  DeviceMessage.fromBytes(List<int> frame)
      : sequence = frame[2],
        payloadType = PayloadType.getByValue(frame[3]),
        payloadLength = bitCombine(frame[4], frame[5]),
        payload = SXiPayload.fromBytes(
            frame.sublist(6, 6 + bitCombine(frame[4], frame[5]))),
        checksum = bitCombine(frame[frame.length - 2], frame[frame.length - 1]);

  // Convert the device message to a byte frame
  List<int> toBytes() {
    List<int> frame = [
      0xDE,
      0xC6,
      sequence,
      payloadType.value,
      (payloadLength >> 8) & 0xFF,
      payloadLength & 0xFF,
      ...payloadAsBytes,
      (checksum >> 8) & 0xFF,
      checksum & 0xFF,
    ];
    return frame;
  }

  // Calculate the checksum of the device message
  int calculateChecksum() {
    int checkValue = 0;
    List<int> frame = [
      0xDE,
      0xC6,
      sequence,
      payloadType.value,
      (payloadLength >> 8) & 0xFF,
      payloadLength & 0xFF,
      ...payloadAsBytes,
    ];
    for (var byte in frame) {
      checkValue =
          ((checkValue + byte) & 0xFF) * 0x100 + (checkValue + byte) + 0x100;
      checkValue = ((checkValue >> 16) ^ checkValue) & 0xFFFF;
    }
    return checkValue;
  }

  // Check if the device message is an acknowledgement message
  bool isAck() {
    int opcode = payload.opcode;
    int firstByte = ((opcode << 18) >> 26) | 0x40;
    int secondByte = (opcode << 18) >> 18;
    return bitCombine(firstByte, secondByte) == opcode;
  }

  // Check if the device message is an init message
  bool isInitMessage() {
    return payloadType.value == 0;
  }

  // Check if the device message is an error message
  bool isError() {
    return payload.runtimeType == SXiErrorIndication;
  }

  @override
  String toString() {
    final payloadBytes = payloadAsBytes;
    final payloadHex =
        payloadBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

    return 'DeviceMessage{'
        'sequence: $sequence, '
        'payloadType: ${payloadType.name}(${payloadType.value}), '
        'payloadLength: $payloadLength, '
        'checksum: 0x${checksum.toRadixString(16).padLeft(4, '0')}, '
        'payload: ${payload.runtimeType.toString().split('.').last}, '
        'payloadBytes: [$payloadHex], '
        'isAck: ${isAck()}, '
        'isInit: ${isInitMessage()}, '
        'isError: ${isError()}, '
        'raw: ${toBytes()}'
        '}';
  }
}

// Link payload type
enum PayloadType {
  init(0),
  control(1),
  data(2),
  audio(3),
  debug(4);

  const PayloadType(this.value);
  final int value;

  static PayloadType getByValue(int i) {
    return PayloadType.values.firstWhere((x) => x.value == i);
  }
}
