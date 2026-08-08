import 'dart:async';
import 'package:orbit/crc.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/data/weather/xm_radar_decoder.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_layer.dart';

// XMApp packet processor
class XmAppProcessor {
  final SXiLayer sxiLayer;
  final XmRadarDecoder _radarDecoder = XmRadarDecoder();
  final Map<String, _XmAppStreamState> _streams = <String, _XmAppStreamState>{};
  final Set<String> _seenRadarFrames = <String>{};
  final Set<String> _reportedRadarDecodeIssues = <String>{};
  Future<void> _radarDecodeChain = Future<void>.value();
  static const Map<int, String> _productNames = <int, String>{
    0x01: 'NEXRAD Radar',
    0x02: 'SCITs',
    0x03: 'Shear',
    0x04: 'Coverage',
    0x05: 'METAR',
    0x06: 'Lightning Strike',
    0x07: 'Echo Tops',
    0x08: 'Precip Type',
    0x09: 'Wind Data',
    0x0B: 'Generic Grid 0x0B',
    0x0C: 'Generic Grid 0x0C',
    0x0D: 'Generic Grid 0x0D',
    0x0E: 'Generic Grid 0x0E',
    0x0F: 'Generic Grid 0x0F',
    0x10: 'Generic Grid 0x10',
    0x11: 'Cyclone Advisory',
    0x12: 'Generic Grid 0x12',
    0x13: 'Generic Grid 0x13',
    0x14: 'Generic Grid 0x14',
    0x15: 'Generic Grid 0x15',
    0x17: 'Generic Grid 0x17',
    0x18: 'Generic Grid 0x18',
    0x19: 'Generic Grid 0x19',
    0x1B: 'Hurricane Track',
    0x1C: 'AIRMET',
    0x1D: 'Convective Radar',
    0x1F: 'Weather Text Advisory',
    0x22: '0C Isotherm',
    0x23: 'TFR',
    0x24: 'City Forecast',
    0x25: 'Surface Analysis',
    0x26: 'Turbulence',
    0x27: 'CIP',
    0x28: 'SLD',
    0x2A: 'TAF',
    0x2F: 'Raw Product 0x2F',
    0x30: 'Raw Product 0x30',
    0x31: 'Raw Product 0x31',
    0x32: 'SatIR',
    0x33: 'PR Radar',
    0x34: 'Convection Radar',
    0x35: 'Radar-1Hr',
    0x37: 'Canada Radar',
    0x38: 'Coverage (Alt)',
    0x3C: 'OEM Product 0x3C',
    0x3D: 'OEM Product 0x3D',
    0x3E: 'OEM Product 0x3E',
    0x3F: 'OEM Product 0x3F',
    0x42: 'OEM Product 66',
    0x45: 'OEM Product 0x45',
    0x46: 'OEM Product 0x46',
    0x47: 'OEM Product 0x47',
    0x48: 'Weather Product 0x48',
    0x4C: 'OEM Product 76',
    0x5A: 'Canadian METAR',
    0x5B: 'Canadian TAF',
    0x5C: 'Generic Grid 0x5C',
    0x5D: 'Generic Grid 0x5D',
    0x5E: 'Generic Grid 0x5E',
    0x60: 'Generic Grid 0x60',
    0x61: 'Generic Grid 0x61',
    0x62: 'Generic Grid 0x62',
    0x67: 'TAF30',
    0x68: 'HiRes SST Tile',
  };

  XmAppProcessor(this.sxiLayer);

  void processXmAppPacket(int dmi, DataServiceIdentifier dsi, List<int> bytes,
      int lenMsb, int lenLsb) {
    final int packetLength = ((lenMsb << 8) | lenLsb) & 0xFFFF;
    final String dmiName = _dmiLabel(dmi, dsi);
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

    if (dsi == DataServiceIdentifier.none ||
        DataServiceIdentifier.xmAppDsiForAppId(dmi) == null) {
      logger.t('XMApp DMI unknown: $dmiHex DSI: $dsi');
    }

    // Outer envelope
    // [0] EA [1] D0 [2] appId [3] frame [4..6] ? [7] innerLen
    // [8..9] service [10..11] CRC16 over [12..]
    if (bytes.length >= 12 && bytes[0] == 0xEA && bytes[1] == 0xD0) {
      final int appId = bytes[2];
      final int frame = bytes[3];
      final int innerLen = bytes[7];
      final int safeInnerLen =
          (12 + innerLen <= bytes.length) ? innerLen : (bytes.length - 12);
      final List<int> innerChunk = bytes.sublist(12, 12 + safeInnerLen);
      final int providedCrc = (bytes[10] << 8) | bytes[11];
      final int calculatedCrc = CRC16.calculate(innerChunk);

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

      if (state.pendingEscapedTailCode) {
        state.pendingEscapedTailCode = false;
        if (b <= 1) {
          _consumeDecodedXmByte(streamKey, dsi, state, 0xAB);
          _consumeDecodedXmByte(streamKey, dsi, state, 0xCC + b);
        } else {
          logger.t(
              'XMApp stream $streamKey invalid escape code: 0x${b.toRadixString(16)}');
          state.resetAll();
        }
        continue;
      }

      if (state.pendingAbControl) {
        state.pendingAbControl = false;
        if (b == 0xCD) {
          // Start of a new framed message
          state.resetMessageOnly();
          state.synced = true;
          continue;
        }
        if (b == 0xCC) {
          state.pendingEscapedTailCode = true;
          continue;
        }
        // Payload data
        _consumeDecodedXmByte(streamKey, dsi, state, 0xAB);
        _consumeDecodedXmByte(streamKey, dsi, state, b);
        continue;
      }

      if (b == 0xAB) {
        state.pendingAbControl = true;
        continue;
      }

      _consumeDecodedXmByte(streamKey, dsi, state, b);
    }
  }

  void _consumeDecodedXmByte(String streamKey, DataServiceIdentifier dsi,
      _XmAppStreamState state, int b) {
    if (!state.synced) {
      return;
    }

    if (state.expectedLength == null) {
      state.lengthBytes.add(b);

      if (state.lengthBytes.length == 2) {
        // Parser treats framed lengths as little-endian.
        final int len16 = state.lengthBytes[0] | (state.lengthBytes[1] << 8);
        if (len16 != 0xFFFF) {
          if (len16 == 0 || len16 > 0x61A80) {
            logger.t('XMApp stream $streamKey invalid message length: $len16');
            state.resetAll();
          } else {
            state.expectedLength = len16;
          }
        }
      } else if (state.lengthBytes.length == 6) {
        if (state.lengthBytes[0] != 0xFF || state.lengthBytes[1] != 0xFF) {
          logger.t('XMApp stream $streamKey invalid extended length header');
          state.resetAll();
          return;
        }
        final int len32 = state.lengthBytes[2] |
            (state.lengthBytes[3] << 8) |
            (state.lengthBytes[4] << 16) |
            (state.lengthBytes[5] << 24);
        if (len32 == 0 || len32 > 0x61A80) {
          logger.t(
              'XMApp stream $streamKey invalid extended message length: $len32');
          state.resetAll();
        } else {
          state.expectedLength = len32;
        }
      }
      return;
    }

    state.messageBytes.add(b);
    if (state.messageBytes.length == state.expectedLength) {
      _handleCompleteXmMessage(streamKey, dsi, state.messageBytes);
      // Returns to unsynced state and waits for next 0xAB 0xCD marker
      state.resetAll();
    }
  }

  void _handleCompleteXmMessage(
      String streamKey, DataServiceIdentifier dsi, List<int> message) {
    if (message.isEmpty) return;
    final int productId = message[0];
    final String productName = _productNames[productId] ?? 'Unknown';
    final int dmi = int.tryParse(streamKey.split(':').first) ?? -1;
    final String dmiName = _dmiLabel(dmi, dsi);

    if (_isRadarProduct(productId)) {
      logger.i(
          'XMApp radar product dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) len=${message.length}');
      final List<int> messageCopy = List<int>.from(message);
      _radarDecodeChain = _radarDecodeChain
          .then((_) => _handleRadarProduct(
                streamKey: streamKey,
                dmi: dmi,
                dmiName: dmiName,
                productId: productId,
                productName: productName,
                message: messageCopy,
              ))
          .catchError((Object error, StackTrace stack) {
        logger.w(
            'XMApp radar decode chain error dmi=${_hexId(dmi)} id=${_hexId(productId)}: $error');
      });
      return;
    }

    if (_productNames.containsKey(productId)) {
      logger.d(
          'XMApp ${_productFamily(productId)} product dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) len=${message.length}');
    } else {
      logger.t(
          'XMApp unknown product dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} len=${message.length}');
    }
  }

  Future<void> _handleRadarProduct({
    required String streamKey,
    required int dmi,
    required String dmiName,
    required int productId,
    required String productName,
    required List<int> message,
  }) async {
    final XmRadarDecodeResult? result =
        await _radarDecoder.decodeAsync(message);
    if (result == null) {
      logger.w(
          'XMApp radar packet rejected dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) len=${message.length}');
      return;
    }

    if (result.overlay == null) {
      final String issueKey =
          '$streamKey:$productId:${result.packet.timestampUtc.millisecondsSinceEpoch}:${result.error}';
      if (_reportedRadarDecodeIssues.add(issueKey)) {
        if (_reportedRadarDecodeIssues.length > 128) {
          _reportedRadarDecodeIssues.remove(_reportedRadarDecodeIssues.first);
        }
        logger.d(
            'XMApp radar decode failed dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) '
            'mode=${_hexId(result.packet.mode)} reason=${result.error}');
      }
      return;
    }

    final String frameKey =
        '$streamKey:$productId:${result.packet.timestampUtc.millisecondsSinceEpoch}:'
        '${result.packet.centerLatDeg.toStringAsFixed(6)}:${result.packet.centerLonDeg.toStringAsFixed(6)}:'
        '${result.packet.spanLonDeg.toStringAsFixed(6)}:${result.packet.width}x${result.packet.height}';
    if (!_seenRadarFrames.add(frameKey)) {
      return;
    }
    if (_seenRadarFrames.length > 128) {
      _seenRadarFrames.remove(_seenRadarFrames.first);
    }

    sxiLayer.appState
        .addRadarOverlay(result.overlay!, result.packet.timestampUtc);
    logger.i(
        'XMApp radar overlay added dmi=${_hexId(dmi)} ($dmiName) id=${_hexId(productId)} ($productName) '
        'center=[${result.packet.centerLatDeg.toStringAsFixed(6)},${result.packet.centerLonDeg.toStringAsFixed(6)}] '
        'spanLon=${result.packet.spanLonDeg.toStringAsFixed(6)} '
        'ts=${result.packet.timestampUtc.toIso8601String()} '
        'size=${result.packet.width}x${result.packet.height}');
  }

  bool _isRadarProduct(int productId) =>
      productId == 0x01 ||
      productId == 0x1D ||
      productId == 0x33 ||
      productId == 0x34 ||
      productId == 0x35 ||
      productId == 0x37;

  String _productFamily(int productId) {
    if (_isRadarProduct(productId)) return 'radar';
    switch (productId) {
      case 0x05:
      case 0x11:
      case 0x1B:
      case 0x1C:
      case 0x1F:
      case 0x23:
      case 0x24:
      case 0x25:
      case 0x2A:
      case 0x42:
      case 0x4C:
      case 0x5A:
      case 0x5B:
      case 0x67:
        return 'text';
      case 0x02:
      case 0x03:
      case 0x04:
      case 0x06:
      case 0x07:
      case 0x08:
      case 0x09:
      case 0x0B:
      case 0x0C:
      case 0x0D:
      case 0x0E:
      case 0x0F:
      case 0x10:
      case 0x12:
      case 0x13:
      case 0x14:
      case 0x15:
      case 0x17:
      case 0x18:
      case 0x19:
      case 0x22:
      case 0x26:
      case 0x27:
      case 0x28:
      case 0x32:
      case 0x38:
      case 0x5C:
      case 0x5D:
      case 0x5E:
      case 0x60:
      case 0x61:
      case 0x62:
      case 0x68:
        return 'grid';
      case 0x2F:
      case 0x30:
      case 0x31:
        return 'raw';
      case 0x3C:
      case 0x3D:
      case 0x3E:
      case 0x3F:
      case 0x45:
      case 0x46:
      case 0x47:
      case 0x48:
        return 'oem';
      default:
        return _productNames.containsKey(productId) ? 'known' : 'unknown';
    }
  }

  String _dmiLabel(int dmi, DataServiceIdentifier dsi) {
    if (dsi != DataServiceIdentifier.none) {
      return dsi.name;
    }
    final DataServiceIdentifier? mapped =
        DataServiceIdentifier.xmAppDsiForAppId(dmi);
    if (mapped != null) {
      return mapped.name;
    }
    return 'unknown';
  }

  String _hexId(int value) => '0x${value.toRadixString(16).padLeft(2, '0')}';
}

class _XmAppStreamState {
  bool synced = false;
  bool pendingAbControl = false;
  bool pendingEscapedTailCode = false;
  final List<int> lengthBytes = <int>[];
  int? expectedLength;
  final List<int> messageBytes = <int>[];

  void resetMessageOnly() {
    lengthBytes.clear();
    expectedLength = null;
    messageBytes.clear();
  }

  void resetAll() {
    synced = false;
    pendingAbControl = false;
    pendingEscapedTailCode = false;
    resetMessageOnly();
  }
}
