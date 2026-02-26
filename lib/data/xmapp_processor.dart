import 'package:orbit/logging.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';

// XMApp packet processor
class XmAppProcessor {
  final SXiLayer sxiLayer;
  final Map<String, _XmAppStreamState> _streams = <String, _XmAppStreamState>{};
  static const Map<int, String> _dmiNames = <int, String>{
    0x08: 'XM NavTraffic',
    0x0A: 'AppID 10 Wx Products',
    0x0E: 'XM NavWeather',
    0x14: 'Proprietary',
    0x15: 'Proprietary',
    0x16: 'Proprietary',
    0x32: 'Stock Symbols',
    0x33: 'Stock Values',
    0x34: 'Stock Extended Values',
    0x35: 'Stock/Sports - Provider IDs',
    0x3C: 'Sports - Menu Item',
    0x3D: 'Sports - Menu Level',
    0x3E: 'Sports - Menu Display',
    0x3F: 'Sports - Menu Alert',
    0x40: 'Proprietary',
    0x41: 'Proprietary',
    0x46: 'Channel Graphics - Logos',
    0x47: 'Channel Graphics - References',
    0x4D: 'Proprietary',
    0x65: 'Proprietary',
    0x66: 'Proprietary',
    0x67: 'Proprietary',
    0x68: 'Proprietary',
    0xE6: 'AppID 230 Wx Products',
    0xE7: 'AppID 231 Wx Products',
    0xE8: 'AppID 232 Wx Products',
    0xEA: 'AppID 234 Wx Products',
    0xEB: 'AppID 235 Wx Products',
    0xEC: 'AppID 236 Wx Products',
    0xED: 'AppID 237 Wx Products',
    0xEE: 'AppID 238 Wx Products',
    0x100: 'Proprietary',
    0x13F: 'Proprietary',
  };
  static const Map<int, String> _productNames = <int, String>{
    0x01: 'NEXRAD Radar',
    0x02: 'County Warnings',
    0x03: 'Storm Cell Attributes',
    0x04: 'Storm Tracks',
    0x05: 'Lightning',
    0x06: 'Echo Tops',
    0x07: 'Severe Storm Watches',
    0x08: 'Surface Analysis',
    0x09: 'City Forecast',
    0x0A: 'Marine Zone Forecast',
    0x0B: 'County Forecast',
    0x0C: 'Wind Aloft',
    0x0D: 'METAR',
    0x0E: 'TAF',
    0x0F: 'AIRMET',
    0x10: 'SIGMET',
    0x11: 'Convective SIGMET',
    0x12: 'PIREP',
    0x13: 'TFR',
    0x14: 'Freezing Level',
    0x15: 'Icing',
    0x16: 'Turbulence',
    0x17: 'Satellite Cloud Tops',
    0x18: 'Satellite Infrared',
    0x19: 'Satellite Visible',
    0x1A: 'Surface Forecast',
    0x1B: 'Hurricane Track',
    0x1C: 'Radar Mosaic (Regional)',
    0x1D: 'Radar Mosaic (CONUS)',
    0x1E: 'Forecast / Advisory',
    0x1F: 'Weather Text Advisory',
    0x20: 'Marine Advisory',
    0x21: 'Surface / Marine Analysis',
    0x22: 'Lightning Density / Strike Grid',
    0x23: 'Weather Product 0x23',
    0x24: 'Weather Product 0x24',
    0x25: 'Weather Product 0x25',
    0x26: 'Weather Product 0x26',
    0x27: 'Weather Product 0x27',
    0x28: 'Weather Product 0x28',
    0x29: 'Weather Product 0x29',
    0x2A: 'Weather Product 0x2A',
    0x2B: 'Weather Product 0x2B',
    0x2C: 'Weather Product 0x2C',
    0x2D: 'Weather Product 0x2D',
    0x2E: 'Weather Product 0x2E',
    0x2F: 'Weather Product 0x2F',
    0x33: 'PR Radar',
    0x34: 'PR Radar (Alt)',
    0x55: 'XMLink Product 0x55',
    0x63: 'XMLink Product 0x63',
    0x80: 'XMLink Product 0x80',
    0xE5: 'Wx Product Family 229',
    0xE6: 'Wx Product Family 230',
    0xE7: 'Wx Product Family 231',
    0xE8: 'Wx Product Family 232',
    0xEA: 'Wx Product Family 234',
    0xEB: 'Wx Product Family 235',
    0xEC: 'Wx Product Family 236',
    0xED: 'Wx Product Family 237',
    0xEE: 'Wx Product Family 238',
  };

  XmAppProcessor(this.sxiLayer);

  void processXmAppPacket(int dmi, DataServiceIdentifier dsi, List<int> bytes,
      int lenMsb, int lenLsb) {
    final int packetLength = ((lenMsb << 8) | lenLsb) & 0xFFFF;
    final String dmiName = _dmiNames[dmi] ?? 'Unknown';
    final String dmiHex = _hexId(dmi);

    if (bytes.isEmpty) {
      logger.t(
          'Ignoring empty XMApp packet for DMI: $dmiHex ($dmiName), DSI: $dsi');
      return;
    }

    if (packetLength != bytes.length) {
      logger.t(
          'XMApp packet length mismatch for DMI: $dmiHex ($dmiName), DSI: $dsi expected $packetLength got ${bytes.length}');
    }

    if (_dmiNames.containsKey(dmi)) {
      logger.d('XMApp DMI recognized: $dmiHex ($dmiName) DSI: $dsi');
    } else {
      logger.t('XMApp DMI unknown: $dmiHex DSI: $dsi');
    }

    // Outer envelope
    // [0] EA [1] D0 [2] appId [3] frame [4..6] ? [7] innerLen
    // [8..9] service [10..11] CRC16 over [12..]
    if (bytes.length >= 12 && bytes[0] == 0xEA && bytes[1] == 0xD0) {
      final int appId = bytes[2];
      final int frame = bytes[3];
      final int innerLen = bytes[7];
      final int service = (bytes[8] << 8) | bytes[9];
      final int safeInnerLen =
          (12 + innerLen <= bytes.length) ? innerLen : (bytes.length - 12);
      final List<int> innerChunk = bytes.sublist(12, 12 + safeInnerLen);
      final int providedCrc = (bytes[10] << 8) | bytes[11];
      final int calculatedCrc = _crc16(innerChunk);

      logger.d(
          'XMApp frame DSI: $dsi DMI: $dmiHex ($dmiName) appId: ${_hexId(appId)} frame: ${_hexId(frame)} service: ${_hexId(service)} innerLen: $innerLen safeInnerLen: $safeInnerLen');

      if (providedCrc != calculatedCrc) {
        logger.t(
            'XMApp frame CRC mismatch DSI: $dsi DMI: $dmiHex ($dmiName) appId: ${_hexId(appId)} frame: ${_hexId(frame)} expected: ${_hexId(providedCrc)} got: ${_hexId(calculatedCrc)}');
      }

      final String streamKey = '$dmi:$appId';
      final _XmAppStreamState state =
          _streams.putIfAbsent(streamKey, () => _XmAppStreamState());
      _feedInnerStream(streamKey, dsi, state, innerChunk);
      return;
    }

    // Fallback
    final String rawKey = '$dmi:raw';
    final _XmAppStreamState rawState =
        _streams.putIfAbsent(rawKey, () => _XmAppStreamState());
    _feedInnerStream(rawKey, dsi, rawState, bytes);
  }

  void _feedInnerStream(String streamKey, DataServiceIdentifier dsi,
      _XmAppStreamState state, List<int> chunk) {
    for (int byte in chunk) {
      int b = byte & 0xFF;

      if (!state.inSync) {
        if (b == 0xAB) {
          state.resetMessageOnly();
          state.inSync = true;
        }
        continue;
      }

      if (state.expectingEscapeCode) {
        if (b <= 1) {
          // Mapping: 0 -> 0xCC, 1 -> 0xCD
          b = 0xCC + b;
          state.expectingEscapeCode = false;
        } else {
          logger.t(
              'XMApp stream $streamKey invalid escape code: 0x${b.toRadixString(16)}');
          state.resetAll();
          continue;
        }
      } else if (b == 0xCC) {
        state.expectingEscapeCode = true;
        continue;
      }

      if (state.expectedLength == null) {
        state.lengthBytes.add(b);

        if (state.lengthBytes.length == 2) {
          final int len16 = (state.lengthBytes[0] << 8) | state.lengthBytes[1];
          if (len16 != 0xFFFF) {
            if (len16 == 0 || len16 > 0x61A80) {
              logger
                  .t('XMApp stream $streamKey invalid message length: $len16');
              state.resetAll();
            } else {
              state.expectedLength = len16;
            }
          }
        } else if (state.lengthBytes.length == 6) {
          if (state.lengthBytes[0] != 0xFF || state.lengthBytes[1] != 0xFF) {
            logger.t('XMApp stream $streamKey invalid extended length header');
            state.resetAll();
            continue;
          }
          final int len32 = (state.lengthBytes[2] << 24) |
              (state.lengthBytes[3] << 16) |
              (state.lengthBytes[4] << 8) |
              state.lengthBytes[5];
          if (len32 == 0 || len32 > 0x61A80) {
            logger.t(
                'XMApp stream $streamKey invalid extended message length: $len32');
            state.resetAll();
          } else {
            state.expectedLength = len32;
          }
        }
        continue;
      }

      state.messageBytes.add(b);
      final int expectedLength = state.expectedLength!;
      if (state.messageBytes.length < expectedLength) {
        final int progressBucket =
            ((state.messageBytes.length * 100) ~/ expectedLength) ~/ 10;
        if (progressBucket > state.lastLoggedProgressBucket) {
          state.lastLoggedProgressBucket = progressBucket;
          logger.d(
              'XMApp stream $streamKey message progress: ${progressBucket * 10}% (${state.messageBytes.length}/$expectedLength)');
        }
      }

      if (state.messageBytes.length == expectedLength) {
        _handleCompleteXmMessage(streamKey, dsi, state.messageBytes);
        state.resetAll();
      }
    }
  }

  void _handleCompleteXmMessage(
      String streamKey, DataServiceIdentifier dsi, List<int> message) {
    if (message.isEmpty) return;
    final int productId = message[0];
    final String productName = _productNames[productId] ?? 'Unknown';
    final int dmi = int.tryParse(streamKey.split(':').first) ?? -1;
    final String dmiName = _dmiNames[dmi] ?? 'Unknown';
    logger.d(
        'XMApp message complete DSI: $dsi DMI: ${_hexId(dmi)} ($dmiName) stream: $streamKey productId: ${_hexId(productId)} ($productName) len: ${message.length} preview: ${_hexPreview(message)}');

    if (_isRadarProduct(productId)) {
      logger.i(
          'XMApp radar product received dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) len=${message.length}');
    } else if (_isAviationTextProduct(productId)) {
      logger.i(
          'XMApp aviation text product received dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) len=${message.length}');
    } else if (_productNames.containsKey(productId)) {
      logger.i(
          'XMApp known product received dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) len=${message.length}');
    } else {
      logger.t(
          'XMApp unknown product dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} len=${message.length}');
    }

    if (_isWeatherDmi(dmi)) {
      logger.d(
          'XMApp weather DMI payload observed: dmi=${_hexId(dmi)} ($dmiName), product=${_hexId(productId)} ($productName)');
    }
  }

  int _crc16(List<int> data) {
    int crc = 0xFFFF;
    for (final int byte in data) {
      crc ^= ((byte & 0xFF) << 8);
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc ^ 0xFFFF;
  }

  bool _isRadarProduct(int productId) =>
      productId == 0x01 || productId == 0x33 || productId == 0x34;

  bool _isAviationTextProduct(int productId) =>
      productId >= 0x0D && productId <= 0x13;

  String _hexPreview(List<int> bytes, {int maxLen = 24}) {
    final int take = bytes.length < maxLen ? bytes.length : maxLen;
    final String preview = bytes
        .take(take)
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    if (bytes.length > maxLen) {
      return '$preview ...';
    }
    return preview;
  }

  bool _isWeatherDmi(int dmi) =>
      dmi == 0x0A || dmi == 0x0E || (dmi >= 0xE6 && dmi <= 0xEE);

  String _hexId(int value) => '0x${value.toRadixString(16).padLeft(2, '0')}';
}

class _XmAppStreamState {
  bool inSync = false;
  bool expectingEscapeCode = false;
  final List<int> lengthBytes = <int>[];
  int? expectedLength;
  final List<int> messageBytes = <int>[];
  int lastLoggedProgressBucket = -1;

  void resetMessageOnly() {
    expectingEscapeCode = false;
    lengthBytes.clear();
    expectedLength = null;
    messageBytes.clear();
    lastLoggedProgressBucket = -1;
  }

  void resetAll() {
    inSync = false;
    resetMessageOnly();
  }
}
