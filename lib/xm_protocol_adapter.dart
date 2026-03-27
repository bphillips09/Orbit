import 'dart:async';
import 'dart:typed_data';
import 'package:orbit/helpers.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_indications.dart';
import 'package:orbit/sxi_payload.dart';
import 'package:orbit/debug_tools_stub.dart'
    if (dart.library.io) 'package:orbit/debug_tools.dart';

enum XmMessageCode {
  startup(0x80),
  powerOff(0x81),
  tuneResponse(0x90),
  tuneCancel(0x91),
  muteResponse(0x93),
  channelLabelResponse(0xA0),
  categoryNameResponse(0xA1),
  extendedInfoResponse(0xA2),
  channelInfoResponse(0xA5),
  radioIdReport(0xB1),
  signalStatusC1(0xC1),
  signalStatusC3(0xC3),
  channelMonitorStatus(0xD0),
  channelNameMonitor(0xD1),
  channelCategoryMonitor(0xD2),
  programInfoMonitor(0xD3),
  extendedArtistMonitor(0xD4),
  extendedTitleMonitor(0xD5),
  monitorStatusAckDe(0xDE),
  clock(0xDF),
  firmwareInfo(0xE3),
  xmDataControlStatus(0xCA),
  xmDataPacket(0xEA),
  monitorStatusAckF0(0xF0),
  diagnosticsInfo(0xF1),
  error(0xFF);

  const XmMessageCode(this.value);
  final int value;

  static XmMessageCode? fromByte(int value) {
    for (final XmMessageCode code in XmMessageCode.values) {
      if (code.value == (value & 0xFF)) return code;
    }
    return null;
  }
}

enum XmStatusCode {
  ok(0x01),
  radioAlert(0x02),
  subscriptionAlert(0x03),
  tuningAlert(0x04),
  activationAlert(0x06),
  commandAlert(0x07);

  const XmStatusCode(this.value);
  final int value;

  static XmStatusCode? fromByte(int value) {
    for (final XmStatusCode code in XmStatusCode.values) {
      if (code.value == (value & 0xFF)) return code;
    }
    return null;
  }
}

enum XmStatusDetail {
  ok(0x0100),
  channelRequiresOverlayReceiver(0x0201),
  channelIsDataService(0x0202),
  dataStreamAvailable(0x0203),
  functionUnavailableForDataChannel(0x0204),
  irregularPowerState(0x0206),
  extendedInfoRequiresActiveTunedChannel(0x0212),
  notSubscribed(0x0309),
  notAvailableForCurrentSubscription(0x030A),
  invalidChannelSelection(0x030B),
  activationErrorServiceRefreshRequired(0x030F),
  tunerWillProvideRadioId(0x040E),
  noSignalCheckAntenna(0x0410),
  activationInfoFetchIssue(0x060B),
  commandUnsupportedForThisChannel(0x070C),
  tunerMustBePoweredBeforeCommand(0x0710);

  const XmStatusDetail(this.value);
  final int value;

  static XmStatusDetail? fromStatusAndDetail(int status, int detail) {
    final int packed = ((status & 0xFF) << 8) | (detail & 0xFF);
    for (final XmStatusDetail code in XmStatusDetail.values) {
      if (code.value == packed) return code;
    }
    return null;
  }
}

enum XmCommandCode {
  startupBootstrap(0x00),
  powerMode(0x01),
  volume(0x0B),
  tune(0x10),
  tuneCancel(0x11),
  audioMute(0x13),
  requestExtendedInfo(0x22),
  requestChannelInfo(0x25),
  requestRadioId(0x31),
  ping(0x43),
  signalMonitor(0x42),
  channelLabelMonitor(0x50),
  diagnosticsMonitor(0x60),
  diagnosticsInfoRequest(0x70),
  clockMonitor(0x4E);

  const XmCommandCode(this.value);
  final int value;
}

enum XmTuneMode {
  sid(0x01),
  channel(0x02);

  const XmTuneMode(this.value);
  final int value;
}

enum XmChannelInfoMode {
  current(0x08),
  next(0x09);

  const XmChannelInfoMode(this.value);
  final int value;
}

class XmProtocolAdapter {
  XmProtocolAdapter({
    required this.serialHelper,
    required this.port,
    required this.transport,
    required this.dataHandler,
    required this.defaultSidProvider,
    required this.volumeProvider,
    required this.currentChannelProvider,
    required this.currentSidProvider,
    required this.currentCategoryProvider,
    required this.resolveChannelFromSid,
    required this.resolveSidFromChannel,
    required this.emitSxiIndication,
    required this.markRx,
    required this.startHeartbeatMonitor,
    required this.updateConnectionDetail,
    required this.reportError,
    required this.updateRadioId,
    required this.updateChannelData,
  });

  static const List<int> candidateBauds = <int>[9600, 38400, 115200];

  final SerialHelper serialHelper;
  final Object port;
  final SerialTransport transport;
  final void Function(Uint8List) dataHandler;
  final int Function() defaultSidProvider;
  final int Function() volumeProvider;
  final int Function() currentChannelProvider;
  final int Function() currentSidProvider;
  final int Function() currentCategoryProvider;
  final int? Function(int sid) resolveChannelFromSid;
  final int? Function(int channel) resolveSidFromChannel;
  final void Function(SXiPayload payload) emitSxiIndication;
  final void Function() markRx;
  final void Function() startHeartbeatMonitor;
  final void Function(String details, {String title}) updateConnectionDetail;
  final void Function(String details, bool fatal)? reportError;
  final void Function(List<int> radioId)? updateRadioId;
  final void Function(int sid, String artist, String song, int programId)?
      updateChannelData;

  Uint8List _buffer = Uint8List(0);
  Completer<bool>? _initCompleter;
  bool _startupSeen = false;
  List<int> _lastRadioId = <int>[];
  bool _guideSweepActive = false;
  Timer? _guideSweepStartTimer;
  Timer? _guideSweepRefreshTimer;
  Completer<bool>? _postConfigConfirmCompleter;
  DateTime? _lastGuideSweepStartedAt;
  final Set<int> _guideSweepSeenChannels = <int>{};
  int _guideSweepStepCount = 0;
  int _guideSweepNoProgressCount = 0;
  int _guideSweepStartChannel = 1;
  static const int _guideSweepMaxSteps = 320;
  static const Duration _guideSweepRefreshInterval = Duration(minutes: 1);
  Future<void> _txChain = Future<void>.value();
  static const Duration _defaultTxPace = Duration(milliseconds: 25);

  void reset() {
    _buffer = Uint8List(0);
    _initCompleter = null;
    _startupSeen = false;
    _lastRadioId = <int>[];
    _guideSweepActive = false;
    _guideSweepStartTimer?.cancel();
    _guideSweepStartTimer = null;
    _guideSweepRefreshTimer?.cancel();
    _guideSweepRefreshTimer = null;
    _lastGuideSweepStartedAt = null;
    _postConfigConfirmCompleter = null;
    _guideSweepSeenChannels.clear();
    _guideSweepStepCount = 0;
    _guideSweepNoProgressCount = 0;
    _guideSweepStartChannel = 1;
    _txChain = Future<void>.value();
  }

  Future<bool> attemptStartup({
    required Duration initTimeout,
    required int maxRxBufferBytes,
  }) async {
    if (transport == SerialTransport.network) {
      return false;
    }

    updateConnectionDetail('Connecting with XM protocol...');
    logger.i('XM startup begin: port: $port transport: $transport');

    for (final int baud in candidateBauds) {
      logger.d('XM startup attempt: baud: $baud');
      try {
        await serialHelper.closePort();
      } catch (_) {}

      reset();
      _initCompleter = Completer<bool>();

      if (!await serialHelper.openPort(port, baud, transport: transport)) {
        logger.w('XM startup open failed: baud: $baud');
        continue;
      }

      logger.i('XM startup open ok: baud: $baud');

      serialHelper.readData(dataHandler, (error, expectedClosure) {
        if (!expectedClosure) {
          logger.e('XM RX stream error: $error');
          reportError?.call(error.toString(), true);
        }
      });

      logger.t('XM RX stream attached: baud: $baud');

      _sendCommand(_xmStartupBootstrapCommand(), paced: true);
      _sendCommand(_xmSignalMonitorCommand(enable: true), paced: true);

      final bool booted = await _waitForInit(
          timeout: initTimeout, maxRxBufferBytes: maxRxBufferBytes);
      logger.i('XM startup init wait result: baud: $baud booted: $booted');
      if (!booted) {
        try {
          await serialHelper.closePort();
        } catch (_) {}
        logger.w('XM startup timeout at baud: $baud, moving to next baud');
        continue;
      }

      logger.i('Connected using XM protocol at $baud baud');
      startHeartbeatMonitor();
      _postConfigConfirmCompleter = Completer<bool>();
      await sendConfigPayload();
      final bool configConfirmed = await _waitForPostConfigConfirm(
        timeout: const Duration(seconds: 4),
      );
      if (!configConfirmed) {
        logger.w(
            'XM post-config confirm timeout at baud: $baud, trying next baud');
        _postConfigConfirmCompleter = null;
        try {
          await serialHelper.closePort();
        } catch (_) {}
        continue;
      }
      _postConfigConfirmCompleter = null;
      return true;
    }

    return false;
  }

  Future<bool> _waitForInit({
    required Duration timeout,
    required int maxRxBufferBytes,
  }) async {
    final completer = _initCompleter;
    if (completer == null) {
      return false;
    }
    final bool result = await Future.any<bool>(<Future<bool>>[
      completer.future,
      Future<bool>.delayed(timeout, () => false),
    ]);
    if (!result) {
      logger.w(
          'XM init wait timed out: startupSeen: $_startupSeen buffered: ${_buffer.length}');
    }
    return result;
  }

  void processData(Uint8List data, {required int maxRxBufferBytes}) {
    markRx();
    _buffer = Uint8List.fromList(_buffer + data);

    if (_buffer.length > maxRxBufferBytes) {
      logger.w('XM protocol buffer too large, resetting...');
      _buffer = Uint8List(0);
      return;
    }

    while (_buffer.length >= 6) {
      if (!(_buffer[0] == 0x5A && _buffer[1] == 0xA5)) {
        int next = -1;
        for (int i = 1; i + 1 < _buffer.length; i++) {
          if (_buffer[i] == 0x5A && _buffer[i + 1] == 0xA5) {
            next = i;
            break;
          }
        }
        _buffer = next >= 0 ? _buffer.sublist(next) : _buffer.sublist(1);
        continue;
      }

      final int payloadLength = bitCombine(_buffer[2], _buffer[3]);
      final int frameLength = 4 + payloadLength + 2;
      if (_buffer.length < frameLength) {
        break;
      }

      final List<int> frame = _buffer.sublist(0, frameLength);
      final List<int> payload = frame.sublist(4, 4 + payloadLength);
      _processPayload(payload);
      _buffer = _buffer.sublist(frameLength);
    }
  }

  void _processPayload(List<int> payload) {
    if (payload.isEmpty) return;

    markRx();

    final XmMessageCode? code = XmMessageCode.fromByte(payload[0]);
    if (code == null) return;
    switch (code) {
      case XmMessageCode.startup:
        _startupSeen = true;
        _initCompleter?.complete(true);
        _initCompleter = null;
        _handleStartup(payload);
        break;
      case XmMessageCode.powerOff:
        _handlePowerOff(payload);
        break;
      case XmMessageCode.tuneResponse:
        _handleTuneResponse(payload);
        break;
      case XmMessageCode.tuneCancel:
        _handleTuneCancel(payload);
        break;
      case XmMessageCode.muteResponse:
        _handleMuteResponse(payload);
        break;
      case XmMessageCode.channelLabelResponse:
        _handleChannelLabelResponse(payload);
        break;
      case XmMessageCode.categoryNameResponse:
        _handleCategoryNameResponse(payload);
        break;
      case XmMessageCode.channelInfoResponse:
        _handleChannelInfo(payload);
        break;
      case XmMessageCode.extendedInfoResponse:
        _handleExtendedInfo(payload);
        break;
      case XmMessageCode.channelMonitorStatus:
        _handleChannelMonitorStatus(payload);
        break;
      case XmMessageCode.channelNameMonitor:
        _handleChannelNameMonitor(payload);
        break;
      case XmMessageCode.channelCategoryMonitor:
        _handleChannelCategoryMonitor(payload);
        break;
      case XmMessageCode.programInfoMonitor:
        _handleProgramInfoMonitor(payload);
        break;
      case XmMessageCode.extendedArtistMonitor:
        _handleExtendedArtistMonitor(payload);
        break;
      case XmMessageCode.extendedTitleMonitor:
        _handleExtendedTitleMonitor(payload);
        break;
      case XmMessageCode.signalStatusC1:
      case XmMessageCode.signalStatusC3:
        _handleSignal(payload);
        break;
      case XmMessageCode.clock:
        _handleClock(payload);
        break;
      case XmMessageCode.monitorStatusAckDe:
      case XmMessageCode.monitorStatusAckF0:
        _handleMonitorStatusAck(payload);
        break;
      case XmMessageCode.diagnosticsInfo:
        _handleDiagnosticsInfo(payload);
        break;
      case XmMessageCode.firmwareInfo:
        _handleFirmwareInfo(payload);
        break;
      case XmMessageCode.xmDataControlStatus:
        _handleXmDataControlStatus(payload);
        break;
      case XmMessageCode.xmDataPacket:
        _handleXmDataPacket(payload);
        break;
      case XmMessageCode.radioIdReport:
        if (payload.length >= 12) {
          final List<int> radioId = payload.sublist(4, 12);
          _lastRadioId = List<int>.from(radioId, growable: false);
          updateRadioId?.call(_lastRadioId);
          final String knownRadioId = _knownRadioId();
          if (knownRadioId.isNotEmpty) {
            updateConnectionDetail('Radio ID: $knownRadioId',
                title: 'XM Radio ID');
          }
        }
        break;
      case XmMessageCode.error:
        logger.w('XM device status error payload: ${_hex(payload)}');
        reportError?.call(_statusMessage(payload), false);
        break;
    }
  }

  void _handleStartup(List<int> payload) {
    logger.d('XM startup payload received: length: ${payload.length}');
    if (payload.length >= 27) {
      final int sub = _mapXmSubscriptionStatus(payload[1] & 0xFF);
      updateRadioId?.call(payload.sublist(19, 27));
      _emitSubscriptionStatus(
        subscriptionStatus: sub,
        radioId: payload.sublist(19, 27),
      );
    }
    _sendCommand(_xmClockMonitorCommand(enable: true), paced: true);
    _sendCommand(_xmPingCommand(), paced: true);
  }

  void _handlePowerOff(List<int> payload) {
    final int indCode = (payload.length >= 3 &&
            XmStatusDetail.fromStatusAndDetail(payload[1], payload[2]) ==
                XmStatusDetail.ok)
        ? IndicationCode.nominal.value
        : IndicationCode.requestedOperationFailed.value;
    final List<int> frame = <int>[0x80, 0x21, 0x00, indCode];

    emitSxiIndication(SXiPowerModeIndication.fromBytes(frame));
  }

  void _handleTuneCancel(List<int> payload) {
    final int channel = payload.length >= 4 ? (payload[3] & 0xFF) : 0;
    _emitSxiDisplayAdvisory(
      IndicationCode.scanAborted,
      channel: channel,
    );
  }

  void _handleTuneResponse(List<int> payload) {
    logger.d('XM tune response payload: ${_hex(payload)}');
    if (payload.length < 6) return;
    if (_postConfigConfirmCompleter != null &&
        !_postConfigConfirmCompleter!.isCompleted) {
      _postConfigConfirmCompleter!.complete(true);
      _postConfigConfirmCompleter = null;
    }
    final int status = payload[1] & 0xFF;
    final int detail = payload[2] & 0xFF;
    final int requestedChannel = payload[4] & 0xFF;
    if (XmStatusDetail.fromStatusAndDetail(status, detail) !=
        XmStatusDetail.ok) {
      if (XmStatusDetail.fromStatusAndDetail(status, detail) ==
          XmStatusDetail.tunerWillProvideRadioId) {
        _sendCommand(_xmRequestRadioIdCommand(), paced: true);
        final String knownRadioId = _knownRadioId();
        updateConnectionDetail(
          knownRadioId.isNotEmpty
              ? 'Radio ID: $knownRadioId'
              : 'Requesting Radio ID from tuner...',
          title: 'XM Radio ID',
        );
        return;
      }
      XmStatusDetail? statusDetail =
          XmStatusDetail.fromStatusAndDetail(status, detail);
      logger.w('XM tune response status detail: $statusDetail');
      final IndicationCode? advisory = _mapTuneFailureToSxiAdvisory(
          statusDetail: statusDetail ?? XmStatusDetail.invalidChannelSelection);
      if (advisory != null) {
        _emitSxiDisplayAdvisory(advisory, channel: requestedChannel);
        return;
      }
      reportError?.call(_statusMessage(payload), false);
      return;
    }
    final int sid = payload[3] & 0xFF;
    final int channel = payload[4] & 0xFF;
    _emitSelectChannel(
      channel: channel,
      sid: sid,
      category: currentCategoryProvider(),
      channelName: '',
      artist: '',
      song: '',
    );
    _sendCommand(
        _xmChannelInfoCommand(
            channel: channel, mode: XmChannelInfoMode.current),
        paced: true);
    _sendCommand(_xmExtendedInfoCommand(channel: channel), paced: true);
    _sendCommand(_xmLabelMonitorCommand(channel: channel, enable: true),
        paced: true);
    if (channel > 0) {
      _scheduleGuideSweepStart(seedChannel: channel);
    }
  }

  IndicationCode? _mapTuneFailureToSxiAdvisory({
    required XmStatusDetail statusDetail,
  }) {
    switch (statusDetail) {
      case XmStatusDetail.notSubscribed:
      case XmStatusDetail.notAvailableForCurrentSubscription:
        return IndicationCode.channelUnsubscribed;
      case XmStatusDetail.invalidChannelSelection:
      case XmStatusDetail.channelIsDataService:
        return IndicationCode.channelUnavailable;
      default:
        return null;
    }
  }

  void _emitSxiDisplayAdvisory(
    IndicationCode advisory, {
    required int channel,
  }) {
    final (int chanMsb, int chanLsb) = bitSplit(channel);
    final List<int> frame = <int>[
      0x80,
      0xC0,
      0x00,
      advisory.value,
      0x01,
      chanMsb,
      chanLsb,
      0x00,
      0x00,
      0x00,
    ];

    emitSxiIndication(SXiDisplayAdvisoryIndication.fromBytes(frame));
    logger.d(
        'Synthesized SXiDisplayAdvisoryIndication: ${advisory.name} channel:$channel');
  }

  void _handleChannelInfo(List<int> payload) {
    if (payload.length < 73) return;
    if (payload[1] != 0x01 || payload[2] != 0x00) return;
    if (_postConfigConfirmCompleter != null &&
        !_postConfigConfirmCompleter!.isCompleted) {
      _postConfigConfirmCompleter!.complete(true);
      _postConfigConfirmCompleter = null;
    }
    final int channel = payload[3];
    final int rawSid = payload[4] & 0xFF;
    final int? sid = _normalizeSidForChannel(channel: channel, rawSid: rawSid);
    if (sid == null) {
      _advanceGuideSweepFrom(channel);
      return;
    }
    final int stationChecksum = payload[5];
    final int catId = payload[23];
    final int categoryChecksum = payload[24];
    final int songChecksum = payload[40];
    final String channelName = _decodeText(payload.sublist(6, 22));
    final String artist = _decodeText(payload.sublist(41, 57));
    final String song = _decodeText(payload.sublist(57, 73));
    final String catName = _decodeText(payload.sublist(24, 40));

    if (categoryChecksum != 0 && catName.isNotEmpty) {
      _emitCategoryInfo(
        category: catId,
        categoryName: catName,
      );
    }
    _emitChannelInfo(
      channel: channel,
      sid: sid,
      category: catId,
      channelName: stationChecksum != 0 ? channelName : '',
    );
    _updateChannelGuideNowPlaying(
      sid: sid,
      artist: artist,
      song: songChecksum != 0 ? song : '',
    );
    if (_isCurrentChannel(channel)) {
      _emitMetadata(
        channel: channel,
        sid: sid,
        artist: artist,
        song: songChecksum != 0 ? song : '',
      );
      _emitSelectChannel(
        channel: channel,
        sid: sid,
        category: catId,
        channelName: stationChecksum != 0 ? channelName : '',
        artist: artist,
        song: songChecksum != 0 ? song : '',
      );
      if (!_guideSweepActive) {
        _emitGuideSweepCompleteSentinels();
      }
    }
    _advanceGuideSweepFrom(channel);
  }

  void _handleChannelLabelResponse(List<int> payload) {
    if (payload.length < 72) return;
    if (payload[1] != 0x01 || payload[2] != 0x00) return;
    if (_postConfigConfirmCompleter != null &&
        !_postConfigConfirmCompleter!.isCompleted) {
      _postConfigConfirmCompleter!.complete(true);
      _postConfigConfirmCompleter = null;
    }

    final int channel = payload[3] & 0xFF;
    final int rawSid = resolveSidFromChannel(channel) ?? channel;
    final int? sid = _normalizeSidForChannel(channel: channel, rawSid: rawSid);
    if (sid == null) return;
    final int stationChecksum = payload[4] & 0xFF;
    final int categoryChecksum = payload[21] & 0xFF;
    final int category = payload[22] & 0xFF;
    final int artistChecksum = payload[39] & 0xFF;
    final String channelName = _decodeText(payload.sublist(5, 21));
    final String categoryName = _decodeText(payload.sublist(23, 39));
    final String artist = _decodeText(payload.sublist(40, 56));
    final String song = _decodeText(payload.sublist(56, 72));

    if (categoryChecksum != 0 && categoryName.isNotEmpty) {
      _emitCategoryInfo(category: category, categoryName: categoryName);
    }
    _emitChannelInfo(
      channel: channel,
      sid: sid,
      category: category,
      channelName: stationChecksum != 0 ? channelName : '',
    );
    _updateChannelGuideNowPlaying(
      sid: sid,
      artist: artistChecksum != 0 ? artist : '',
      song: song,
    );
    if (_isCurrentChannel(channel)) {
      _emitMetadata(
        channel: channel,
        sid: sid,
        artist: artistChecksum != 0 ? artist : '',
        song: song,
      );
      _emitSelectChannel(
        channel: channel,
        sid: sid,
        category: category,
        channelName: stationChecksum != 0 ? channelName : '',
        artist: artistChecksum != 0 ? artist : '',
        song: song,
      );
      if (!_guideSweepActive) {
        _emitGuideSweepCompleteSentinels();
      }
    }
  }

  void _handleCategoryNameResponse(List<int> payload) {
    if (payload.length < 20) return;
    if (payload[1] != 0x01 || payload[2] != 0x00) return;
    final int category = payload[3] & 0xFF;
    final int checksum = payload[4] & 0xFF;
    if (checksum == 0) return;
    final String categoryName = _decodeText(payload.sublist(5, 21));
    if (categoryName.isEmpty) return;
    _emitCategoryInfo(category: category, categoryName: categoryName);
  }

  void _handleExtendedInfo(List<int> payload) {
    if (payload.length < 78) return;
    if (payload[1] != 0x01 || payload[2] != 0x00) return;
    final int channel = payload[3];
    if (!_isCurrentChannel(channel)) return;
    final int? sid = resolveSidFromChannel(channel);
    if (sid == null) return;
    final int artistChecksum = payload[4];
    final int titleChecksum = payload[41];
    if (artistChecksum == 0 && titleChecksum == 0) return;
    final String artist = _decodeText(payload.sublist(5, 41));
    final String song = _decodeText(payload.sublist(42, 78));
    if (artist.isEmpty && song.isEmpty) return;
    logger.d(
        'XM extended metadata received: channel: $channel sid: $sid artistLength: ${artist.length} titleLength: ${song.length}');
    _emitMetadata(
      channel: channel,
      sid: sid,
      artist: artistChecksum != 0 ? artist : '',
      song: titleChecksum != 0 ? song : '',
    );
  }

  void _handleChannelNameMonitor(List<int> payload) {
    if (payload.length < 19) return;
    if (payload[2] == 0x00) return;
    final int channel = payload[1];
    if (!_isCurrentChannel(channel)) return;
    final int? sid = resolveSidFromChannel(channel);
    if (sid == null) return;
    final String channelName = _decodeText(payload.sublist(3, 19));
    if (channelName.isEmpty) return;
    _emitChannelInfo(
      channel: channel,
      sid: sid,
      category: currentCategoryProvider(),
      channelName: channelName,
    );
  }

  void _handleChannelCategoryMonitor(List<int> payload) {
    if (payload.length < 5) return;
    if (payload[3] == 0x00) return;
    final int channel = payload[1];
    if (!_isCurrentChannel(channel)) return;
    final int catId = payload[2];
    final String catName = _decodeText(payload.sublist(4));
    if (catName.isEmpty) return;
    final int? sid = resolveSidFromChannel(channel);
    if (sid == null) return;
    _emitCategoryInfo(category: catId, categoryName: catName);
    _emitChannelInfo(
      channel: channel,
      sid: sid,
      category: catId,
      channelName: '',
    );
  }

  void _handleProgramInfoMonitor(List<int> payload) {
    if (payload.length < 35) return;
    if (payload[2] == 0x00) return;
    final int channel = payload[1];
    if (!_isCurrentChannel(channel)) return;
    final int? sid = resolveSidFromChannel(channel);
    if (sid == null) return;
    final String artist = _decodeText(payload.sublist(3, 19));
    final String song = _decodeText(payload.sublist(19));
    if (artist.isEmpty && song.isEmpty) return;
    _emitMetadata(
      channel: channel,
      sid: sid,
      artist: artist,
      song: song,
    );
  }

  void _handleChannelMonitorStatus(List<int> payload) {
    if (payload.length >= 3 && !(payload[1] == 0x01 && payload[2] == 0x00)) {
      reportError?.call(_statusMessage(payload), false);
    }
  }

  void _handleMuteResponse(List<int> payload) {
    if (payload.length < 3) return;
    if (payload[1] == 0x01 && payload[2] == 0x00) return;
    logger.w(
        'XM mute confirm unsuccessful: status: 0x${payload[1].toRadixString(16).padLeft(2, '0')} detail: 0x${payload[2].toRadixString(16).padLeft(2, '0')}');
  }

  void _handleExtendedArtistMonitor(List<int> payload) {
    if (payload.length < 3) return;
    if (payload[2] == 0x00) return;
    final int channel = payload[1];
    if (!_isCurrentChannel(channel)) return;
    logger.d(
        'XM extended artist monitor update: channel: $channel, requesting extended info');
    _sendCommand(_xmExtendedInfoCommand(channel: channel), paced: true);
  }

  void _handleExtendedTitleMonitor(List<int> payload) {
    if (payload.length < 3) return;
    if (payload[2] == 0x00) return;
    final int channel = payload[1];
    if (!_isCurrentChannel(channel)) return;
    logger.d(
        'XM extended title monitor update: channel: $channel, requesting extended info');
    _sendCommand(_xmExtendedInfoCommand(channel: channel), paced: true);
  }

  void _handleSignal(List<int> payload) {
    if (payload.length != 22 && payload.length != 26) return;
    final List<int> normalized = payload[0] == 0xC1
        ? <int>[payload[0], 0x01, 0x00, ...payload.sublist(1), 0x00, 0x00]
        : payload;
    if (normalized.length < 6) return;
    final int sat = normalized[3];
    final int ant = normalized[4];
    _emitSignalStatus(sat: sat, antennaConnected: ant == 0x03);
  }

  void _handleClock(List<int> payload) {
    if (payload.length != 11) return;
    final int year = (payload[1] * 100) + payload[2];
    final int month = payload[3];
    final int day =
        (payload[4] & 0x0F) + ((((payload[4] >> 4) % 2) == 1) ? 16 : 0);
    final int hour = payload[5];
    final int minute = payload[6];
    _emitTime(minute: minute, hour: hour, day: day, month: month, year: year);
  }

  void _handleMonitorStatusAck(List<int> payload) {
    if (payload.length < 3) return;
    if (payload[1] == 0x01 && payload[2] == 0x00) return;
    reportError?.call(_statusMessage(payload), false);
  }

  void _handleDiagnosticsInfo(List<int> payload) {
    logger.d('XM diagnostic info: ${_hex(payload)}');
  }

  void _handleFirmwareInfo(List<int> payload) {
    logger.i('XM firmware info: ${_hex(payload)}');
  }

  void _handleXmDataControlStatus(List<int> payload) {
    if (payload.length < 3) return;
    logger.d('XM data control status: ${_hex(payload)}');
    if (payload.length >= 4 && payload[1] == 0x40 && payload[2] == 0xFF) {
      reportError?.call(_statusMessage(<int>[0xFF, payload[3], 0x00]), false);
    }
  }

  void _handleXmDataPacket(List<int> payload) {
    if (payload.isEmpty) return;

    final bool isXmAppEnvelope = payload.length >= 2 && payload[1] == 0xD0;
    final int dmi = (payload.length >= 3) ? (payload[2] & 0xFF) : 0x00;
    final (int dmiMsb, int dmiLsb) = bitSplit(dmi);
    final int packetLen = payload.length & 0xFFFF;
    final (int lenMsb, int lenLsb) = bitSplit(packetLen);

    if (isXmAppEnvelope) {
      final int frameId = payload.length >= 4 ? payload[3] & 0xFF : 0;
      logger.d(
          'XM data packet received: dmi: 0x${dmi.toRadixString(16).padLeft(2, '0')} frame: 0x${frameId.toRadixString(16).padLeft(2, '0')} length: $packetLen');
    } else {
      logger.d('XM raw data packet received: length: $packetLen');
    }

    final List<int> frame = <int>[
      0x85,
      0x10,
      0x00,
      isXmAppEnvelope
          ? DataServiceType.xmApp.value
          : DataServiceType.rawDataPacket.value,
      dmiMsb,
      dmiLsb,
      lenMsb,
      lenLsb,
      ...payload,
    ];

    emitSxiIndication(SXiDataPacketIndication.fromBytes(frame));
  }

  bool sendMappedCommand(SXiPayload payload) {
    logger.t('XM mapped command: $payload');
    switch (payload) {
      case SXiPowerModeCommand():
        _sendCommand(_xmPowerModeCommand(powerOn: payload.powerOn),
            paced: true);
        if (payload.powerOn) {
          _sendCommand(_xmSignalMonitorCommand(enable: true), paced: true);
        }
        return true;
      case SXiConfigureTimeCommand():
        _sendCommand(_xmClockMonitorCommand(enable: true), paced: true);
        return true;
      case SXiMonitorFeatureCommand():
        _applyFeatureMonitorCommand(payload);
        return true;
      case SXiMonitorExtendedMetadataCommand():
        final bool enable =
            payload.monitorChangeType == MonitorChangeType.monitor;
        final int channel = currentChannelProvider().clamp(1, 255);
        if (enable) {
          _sendCommand(_xmExtendedInfoCommand(channel: channel), paced: true);
          _sendCommand(_xmLabelMonitorCommand(channel: channel, enable: true),
              paced: true);
        } else {
          _sendCommand(_xmLabelMonitorCommand(channel: channel, enable: false),
              paced: true);
        }
        return true;
      case SXiSelectChannelCommand():
        final int target = payload.channelIDorSID.clamp(0, 255);
        switch (payload.selectionType) {
          case ChanSelectionType.tuneUsingSID:
            _sendTuneCommand(
              target: target,
              useSidMode: true,
            );
            break;
          case ChanSelectionType.tuneUsingChannelNumber:
            _sendTuneCommand(
              target: target,
              useSidMode: false,
            );
            break;
          case ChanSelectionType.tuneToNextHigherChannelNumberInCategory:
            _sendTuneCommand(
              target: (currentChannelProvider() + 1).clamp(0, 255),
              useSidMode: false,
            );
            break;
          case ChanSelectionType.tuneToNextLowerChannelNumberInCategory:
            _sendTuneCommand(
              target: (currentChannelProvider() - 1).clamp(0, 255),
              useSidMode: false,
            );
            break;
          case ChanSelectionType.stopScanAndContinuePlaybackOfCurrentTrack:
          case ChanSelectionType
                .abortScanAndResumePlaybackOfItemActiveAtScanInitiation:
            _sendCommand(
                _xmTuneCancelCommand(
                  channel: currentChannelProvider().clamp(1, 255),
                ),
                paced: true);
            break;
          default:
            logger.d(
                'XM protocol does not support selection: ${payload.selectionType}');
            return false;
        }
        return true;
      case SXiAudioMuteCommand():
        final bool mute = payload.mute != AudioMuteType.unmute;
        _sendCommand(_xmAudioMuteCommand(mute: mute), paced: true);
        return true;
      case SXiAudioVolumeCommand():
        final int volume = payload.volume.clamp(-96, 24);
        final int encoded = volume > 0 ? 0x60 + volume : -volume;
        _sendCommand(_xmVolumeCommand(encodedVolume: encoded & 0xFF),
            paced: true);
        return true;
      case SXiPingCommand():
        _sendCommand(_xmPingCommand(), paced: true);
        return true;
      case SXiMonitorStatusCommand():
        _applyStatusMonitorCommand(payload);
        return true;
      default:
        logger.d(
            'XM protocol ignored unsupported command: ${payload.runtimeType}');
        return false;
    }
  }

  void _applyFeatureMonitorCommand(SXiMonitorFeatureCommand payload) {
    final int channel = currentChannelProvider().clamp(1, 255);
    if (payload.monitorOperation == MonitorChangeType.dontMonitorAll) {
      _sendCommand(_xmClockMonitorCommand(enable: false), paced: true);
      _sendCommand(_xmSignalMonitorCommand(enable: false), paced: true);
      _sendCommand(_xmLabelMonitorCommand(channel: channel, enable: false),
          paced: true);
      return;
    }

    final bool enable = payload.monitorOperation == MonitorChangeType.monitor;
    final Set<FeatureMonitorType> features = payload.featureMonitorIDs.toSet();

    if (features.contains(FeatureMonitorType.time)) {
      _sendCommand(_xmClockMonitorCommand(enable: enable), paced: true);
    }

    final bool needsLabelMonitor =
        features.contains(FeatureMonitorType.channelInfo) ||
            features.contains(FeatureMonitorType.categoryInfo) ||
            features.contains(FeatureMonitorType.metadata);
    if (needsLabelMonitor) {
      _sendCommand(_xmLabelMonitorCommand(channel: channel, enable: enable),
          paced: true);
    }
  }

  void _applyStatusMonitorCommand(SXiMonitorStatusCommand payload) {
    final bool disableAll =
        payload.monitorChangeType == MonitorChangeType.dontMonitorAll;
    final bool enable = payload.monitorChangeType == MonitorChangeType.monitor;
    final Set<StatusMonitorType> items = payload.statusMonitorItems.toSet();

    if (disableAll) {
      _sendCommand(_xmSignalMonitorCommand(enable: false), paced: true);
      _sendCommand(_xmDiagnosticsMonitorCommand(enable: false), paced: true);
      return;
    }

    if (items.contains(StatusMonitorType.signalAndAntennaStatus)) {
      _sendCommand(_xmSignalMonitorCommand(enable: enable), paced: true);
    }

    final bool wantsDiagnostics =
        items.contains(StatusMonitorType.debugDecoder) ||
            items.contains(StatusMonitorType.debugOffset) ||
            items.contains(StatusMonitorType.debugPipe) ||
            items.contains(StatusMonitorType.debugDataLayer) ||
            items.contains(StatusMonitorType.debugQueue) ||
            items.contains(StatusMonitorType.debugMfc) ||
            items.contains(StatusMonitorType.debugAudioDecoder) ||
            items.contains(StatusMonitorType.debugUpc) ||
            items.contains(StatusMonitorType.debugQuality);
    if (wantsDiagnostics) {
      _sendCommand(_xmDiagnosticsMonitorCommand(enable: enable), paced: true);
    }

    if (enable && items.contains(StatusMonitorType.moduleVersion)) {
      _sendCommand(_xmDiagnosticsInfoRequestCommand(), paced: true);
    }
  }

  void _sendTuneCommand({
    required int target,
    required bool useSidMode,
  }) {
    _cancelGuideSweep(emitCompletionSentinels: true);
    final int sanitizedTarget = target.clamp(0, 255);
    logger.d(
        'XM tune request: mode: ${useSidMode ? 'sid' : 'channel'} target: $sanitizedTarget');
    _sendCommand(
      _xmTuneCommand(
        target: sanitizedTarget,
        mode: useSidMode ? XmTuneMode.sid : XmTuneMode.channel,
      ),
      paced: true,
    );
  }

  Future<void> sendConfigPayload() async {
    logger.d('XM config begin');
    _sendCommand(_xmSignalMonitorCommand(enable: true), paced: true);
    _sendCommand(_xmClockMonitorCommand(enable: true), paced: true);
    _sendCommand(_xmRequestRadioIdCommand(), paced: true);

    final int preferredChannel = currentChannelProvider().clamp(1, 255);
    _sendCommand(
        _xmTuneCommand(target: preferredChannel, mode: XmTuneMode.channel),
        paced: true);
    _sendCommand(
        _xmChannelInfoCommand(
            channel: preferredChannel, mode: XmChannelInfoMode.current),
        paced: true);
    _sendCommand(_xmExtendedInfoCommand(channel: preferredChannel),
        paced: true);
    _sendCommand(
        _xmLabelMonitorCommand(channel: preferredChannel, enable: true),
        paced: true);
    _scheduleGuideSweepStart(seedChannel: preferredChannel);

    final int volume = volumeProvider().clamp(-96, 24);
    final int encodedVolume = volume > 0 ? 0x60 + volume : -volume;
    _sendCommand(_xmVolumeCommand(encodedVolume: encodedVolume & 0xFF),
        paced: true);
    _sendCommand(_xmAudioMuteCommand(mute: false), paced: true);
    logger.d(
        'XM config complete: preferredChannel: $preferredChannel volume: $volume encodedVolume: $encodedVolume');
  }

  void _emitSubscriptionStatus({
    required int subscriptionStatus,
    required List<int> radioId,
  }) {
    final List<int> radio = _limitAscii(radioId, 8);
    _lastRadioId = List<int>.from(radio, growable: false);
    final List<int> frame = <int>[
      0x80,
      0xC1,
      0x00,
      IndicationCode.subscriptionUpdate.value,
      ...radio,
      0x00,
      subscriptionStatus & 0xFF,
      0x00,
      0x01,
      0x01,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
    ];

    emitSxiIndication(SXiSubscriptionStatusIndication.fromBytes(frame));
  }

  void _emitCategoryInfo({
    required int category,
    required String categoryName,
  }) {
    final List<int> frame = <int>[
      0x82,
      0x01,
      0x00,
      IndicationCode.nominal.value,
      category & 0xFF,
      ..._sxiString(categoryName, 8),
      ..._sxiString(categoryName, 16),
      ..._sxiString(categoryName, 32),
    ];

    emitSxiIndication(SXiCategoryInfoIndication.fromBytes(frame));
  }

  void _emitChannelInfo({
    required int channel,
    required int sid,
    required int category,
    required String channelName,
  }) {
    final (int chanMsb, int chanLsb) = bitSplit(channel);
    final (int sidMsb, int sidLsb) = bitSplit(sid);
    final List<int> frame = <int>[
      0x82,
      0x81,
      0x00,
      IndicationCode.nominal.value,
      chanMsb,
      chanLsb,
      sidMsb,
      sidLsb,
      0x00,
      0x00,
      category & 0xFF,
      ..._sxiString(channelName, 8),
      ..._sxiString(channelName, 16),
      ..._sxiString(channelName, 32),
    ];

    emitSxiIndication(SXiChannelInfoIndication.fromBytes(frame));
  }

  void _emitSelectChannel({
    required int channel,
    required int sid,
    required int category,
    required String channelName,
    required String artist,
    required String song,
  }) {
    final (int chanMsb, int chanLsb) = bitSplit(channel);
    final (int sidMsb, int sidLsb) = bitSplit(sid);
    final List<int> frame = <int>[
      0x82,
      0x80,
      0x00,
      IndicationCode.nominal.value,
      chanMsb,
      chanLsb,
      sidMsb,
      sidLsb,
      category & 0xFF,
      category & 0xFF,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      ..._sxiString(channelName, 8),
      ..._sxiString(channelName, 16),
      ..._sxiString(channelName, 32),
      ..._sxiString('', 8),
      ..._sxiString('', 16),
      ..._sxiString('', 32),
      ..._sxiString(artist, 16),
      ..._sxiString(song, 16),
      ..._sxiString(artist, 36),
      ..._sxiString(song, 36),
      0x00,
      0x00,
      0x00,
      sidMsb,
      sidLsb,
    ];

    emitSxiIndication(SXiSelectChannelIndication.fromBytes(frame));
  }

  void _emitMetadata({
    required int channel,
    required int sid,
    required String artist,
    required String song,
  }) {
    final (int chanMsb, int chanLsb) = bitSplit(channel);
    final (int sidMsb, int sidLsb) = bitSplit(sid);
    final List<int> frame = <int>[
      0x83,
      0x00,
      0x00,
      IndicationCode.nominal.value,
      chanMsb,
      chanLsb,
      sidMsb,
      sidLsb,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      ..._sxiString(artist, 16),
      ..._sxiString(song, 16),
      ..._sxiString(artist, 36),
      ..._sxiString(song, 36),
      0x00,
      0x00,
    ];

    emitSxiIndication(SXiMetadataIndication.fromBytes(frame));
  }

  void _emitSignalStatus({
    required int sat,
    required bool antennaConnected,
  }) {
    final List<int> frame = <int>[
      0x80,
      0xA0,
      0x00,
      IndicationCode.nominal.value,
      StatusMonitorType.signalAndAntennaStatus.value,
      sat & 0xFF,
      antennaConnected ? 0x00 : 0x01,
    ];

    emitSxiIndication(SXiStatusIndication.fromBytes(frame));
  }

  void _emitTime({
    required int minute,
    required int hour,
    required int day,
    required int month,
    required int year,
  }) {
    // Disabled for now

    //final List<int> frame = <int>[
    //  0x80,
    //  0x60,
    //  0x00,
    //  IndicationCode.nominal.value,
    //  minute & 0xFF,
    //  hour & 0xFF,
    //  day & 0xFF,
    //  month & 0xFF,
    //  (year % 100) & 0xFF,
    //];
    //
    //emitSxiIndication(SXiTimeIndication.fromBytes(frame));
  }

  String _statusMessage(List<int> payload) {
    if (payload.length < 3) {
      return 'XM protocol device reported an error';
    }
    final int status = payload[1];
    final int detail = payload[2];
    switch (XmStatusDetail.fromStatusAndDetail(status, detail)) {
      case XmStatusDetail.ok:
        return 'XM protocol status OK';
      case XmStatusDetail.channelRequiresOverlayReceiver:
        return 'XM protocol: channel requires overlay receiver';
      case XmStatusDetail.channelIsDataService:
        return 'XM tuner: channel is data';
      case XmStatusDetail.dataStreamAvailable:
        return 'XM protocol: data stream available';
      case XmStatusDetail.functionUnavailableForDataChannel:
        return 'XM protocol: function unavailable for data channel';
      case XmStatusDetail.irregularPowerState:
        return 'XM protocol: irregular power state';
      case XmStatusDetail.extendedInfoRequiresActiveTunedChannel:
        return 'XM protocol: extended info requires active tuned channel';
      case XmStatusDetail.notSubscribed:
        return 'XM protocol: not subscribed';
      case XmStatusDetail.notAvailableForCurrentSubscription:
        return 'XM protocol: not available for current subscription';
      case XmStatusDetail.invalidChannelSelection:
        return 'XM protocol: invalid channel selection';
      case XmStatusDetail.activationErrorServiceRefreshRequired:
        return 'XM protocol: activation error; service refresh required';
      case XmStatusDetail.tunerWillProvideRadioId:
        return 'XM protocol: tuner will provide radio ID';
      case XmStatusDetail.noSignalCheckAntenna:
        return 'XM protocol: no signal; check antenna';
      case XmStatusDetail.activationInfoFetchIssue:
        return 'XM protocol: activation info fetch issue';
      case XmStatusDetail.commandUnsupportedForThisChannel:
        return 'XM protocol: command unsupported for this channel';
      case XmStatusDetail.tunerMustBePoweredBeforeCommand:
        return 'XM protocol: tuner must be powered before command';
      default:
        break;
    }
    final XmStatusCode? group = XmStatusCode.fromByte(status);
    if (group == XmStatusCode.radioAlert) {
      return 'XM protocol: radio alert (0x02 0x${detail.toRadixString(16).padLeft(2, '0')})';
    }
    if (group == XmStatusCode.subscriptionAlert) {
      return 'XM protocol: subscription alert (0x03 0x${detail.toRadixString(16).padLeft(2, '0')})';
    }
    if (group == XmStatusCode.tuningAlert) {
      return 'XM protocol: tuning alert (0x04 0x${detail.toRadixString(16).padLeft(2, '0')})';
    }
    if (group == XmStatusCode.activationAlert) {
      return 'XM protocol: activation alert (0x06 0x${detail.toRadixString(16).padLeft(2, '0')})';
    }
    if (group == XmStatusCode.commandAlert) {
      return 'XM protocol: command alert (0x07 0x${detail.toRadixString(16).padLeft(2, '0')})';
    }
    return 'XM protocol status: 0x${status.toRadixString(16).padLeft(2, '0')} '
        '0x${detail.toRadixString(16).padLeft(2, '0')}';
  }

  String _decodeText(List<int> bytes) {
    final int zeroIndex = bytes.indexOf(0);
    final List<int> sliced =
        zeroIndex >= 0 ? bytes.sublist(0, zeroIndex) : bytes;
    return String.fromCharCodes(sliced).trim();
  }

  bool _isCurrentChannel(int channel) {
    final int current = currentChannelProvider();
    return current <= 0 || current == channel;
  }

  int? _normalizeSidForChannel({
    required int channel,
    required int rawSid,
  }) {
    final int? mappedSid = resolveSidFromChannel(channel);
    if (mappedSid != null && mappedSid > 0 && mappedSid != 0xFF) {
      return mappedSid;
    }

    if (rawSid <= 0 || rawSid == 0xFF) return null;

    final int currentSid = currentSidProvider();
    final int currentChannel = currentChannelProvider();
    if (rawSid == currentSid && channel != currentChannel) {
      return null;
    }
    return rawSid;
  }

  void _updateChannelGuideNowPlaying({
    required int sid,
    required String artist,
    required String song,
  }) {
    if (sid <= 0) return;
    final String artistTrimmed = artist.trim();
    final String songTrimmed = song.trim();
    if (artistTrimmed.isEmpty && songTrimmed.isEmpty) return;
    updateChannelData?.call(sid, artistTrimmed, songTrimmed, 0);
  }

  void _startGuideSweep({required int seedChannel}) {
    if (_guideSweepActive) return;
    _guideSweepRefreshTimer?.cancel();
    _guideSweepRefreshTimer = null;
    _lastGuideSweepStartedAt = DateTime.now();
    final int start = seedChannel.clamp(1, 255);
    _guideSweepActive = true;
    _guideSweepSeenChannels.clear();
    _guideSweepStepCount = 0;
    _guideSweepNoProgressCount = 0;
    _guideSweepStartChannel = start;
    logger.d('XM guide sweep start: seedChannel: $start');
    _sendCommand(
        _xmChannelInfoCommand(channel: start, mode: XmChannelInfoMode.current),
        paced: true);
    _sendCommand(
        _xmChannelInfoCommand(channel: start, mode: XmChannelInfoMode.next),
        paced: true);
  }

  void _scheduleGuideSweepStart({required int seedChannel}) {
    _guideSweepStartTimer?.cancel();
    final int start = seedChannel.clamp(1, 255);
    _guideSweepStartTimer = Timer(const Duration(seconds: 5), () {
      _guideSweepStartTimer = null;
      _startGuideSweep(seedChannel: start);
    });
    logger.d('XM guide sweep scheduled in 5s: seedChannel: $start');
  }

  void _advanceGuideSweepFrom(int channel) {
    if (!_guideSweepActive) return;
    if (channel <= 0 || channel > 255) {
      _stopGuideSweep('invalid_channel');
      return;
    }

    final bool isNewChannel = _guideSweepSeenChannels.add(channel);
    if (isNewChannel) {
      _guideSweepNoProgressCount = 0;
    } else {
      _guideSweepNoProgressCount++;
    }
    _guideSweepStepCount++;

    if (channel == _guideSweepStartChannel &&
        _guideSweepSeenChannels.length >= 10 &&
        _guideSweepStepCount >= 10) {
      _stopGuideSweep('wrapped_to_seed');
      return;
    }

    if (_guideSweepStepCount >= _guideSweepMaxSteps) {
      _stopGuideSweep('max_steps');
      return;
    }

    if (_guideSweepNoProgressCount >= 12) {
      _stopGuideSweep('no_progress');
      return;
    }

    _sendCommand(
        _xmChannelInfoCommand(channel: channel, mode: XmChannelInfoMode.next),
        paced: true);
  }

  void _stopGuideSweep(String reason) {
    if (!_guideSweepActive) return;
    final int restartSeed = currentChannelProvider().clamp(1, 255);
    logger.d(
        'XM guide sweep complete: reason: $reason entries: ${_guideSweepSeenChannels.length} steps: $_guideSweepStepCount');
    _cancelGuideSweep(emitCompletionSentinels: true);
    _scheduleGuideSweepRefresh(seedChannel: restartSeed);
  }

  void _scheduleGuideSweepRefresh({required int seedChannel}) {
    _guideSweepRefreshTimer?.cancel();
    final int start = seedChannel.clamp(1, 255);
    _guideSweepRefreshTimer = Timer(_guideSweepRefreshInterval, () {
      _guideSweepRefreshTimer = null;
      if (_guideSweepActive) return;
      _startGuideSweep(seedChannel: start);
    });
    logger.d(
        'XM guide sweep refresh scheduled in ${_guideSweepRefreshInterval.inMinutes}m: seedChannel: $start');
  }

  void requestGuideWalkIfStale({
    Duration staleAfter = const Duration(seconds: 10),
  }) {
    if (_guideSweepActive) return;
    final DateTime? lastStartedAt = _lastGuideSweepStartedAt;
    if (lastStartedAt != null &&
        DateTime.now().difference(lastStartedAt) < staleAfter) {
      return;
    }
    _guideSweepStartTimer?.cancel();
    _guideSweepStartTimer = null;
    _startGuideSweep(seedChannel: currentChannelProvider().clamp(1, 255));
  }

  void _emitGuideSweepCompleteSentinels() {
    _emitCategoryInfo(category: 0xFF, categoryName: '');
    _emitChannelInfo(
      channel: 0,
      sid: 0,
      category: 0xFF,
      channelName: '',
    );
  }

  void _cancelGuideSweep({bool emitCompletionSentinels = false}) {
    final bool wasActive = _guideSweepActive;
    _guideSweepActive = false;
    _guideSweepStartTimer?.cancel();
    _guideSweepStartTimer = null;
    _guideSweepRefreshTimer?.cancel();
    _guideSweepRefreshTimer = null;
    _guideSweepSeenChannels.clear();
    _guideSweepStepCount = 0;
    _guideSweepNoProgressCount = 0;
    if (emitCompletionSentinels && wasActive) {
      _emitGuideSweepCompleteSentinels();
    }
  }

  Future<bool> _waitForPostConfigConfirm({
    required Duration timeout,
  }) async {
    final Completer<bool>? completer = _postConfigConfirmCompleter;
    if (completer == null) return false;
    return await Future.any<bool>(<Future<bool>>[
      completer.future,
      Future<bool>.delayed(timeout, () => false),
    ]);
  }

  String _knownRadioId() {
    if (_lastRadioId.isEmpty) return '';
    final List<int> trimmed =
        _lastRadioId.where((int b) => b != 0x00 && b != 0x20).toList();
    if (trimmed.isEmpty) return '';
    final String ascii = String.fromCharCodes(trimmed)
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .trim();
    return ascii;
  }

  int _mapXmSubscriptionStatus(int xmStatus) {
    switch (xmStatus) {
      case 0x01:
        return SubscriptionStatus.full.value;
      case 0x02:
        return SubscriptionStatus.partial.value;
      case 0x03:
        return SubscriptionStatus.none.value;
      default:
        return SubscriptionStatus.unknown.value;
    }
  }

  List<int> _limitAscii(List<int> value, int maxLen) {
    if (value.length <= maxLen) return List<int>.from(value);
    return value.sublist(0, maxLen);
  }

  List<int> _sxiString(String value, int maxLen) {
    final List<int> ascii = value.codeUnits
        .map((int c) => c & 0xFF)
        .take(maxLen)
        .toList(growable: false);
    return <int>[...ascii, 0x00];
  }

  List<int> _xmStartupBootstrapCommand() =>
      <int>[XmCommandCode.startupBootstrap.value, 0x10, 0x10, 0x24, 0x01];

  List<int> _xmPowerModeCommand({required bool powerOn}) =>
      <int>[XmCommandCode.powerMode.value, powerOn ? 0x01 : 0x00];

  List<int> _xmSignalMonitorCommand({required bool enable}) =>
      <int>[XmCommandCode.signalMonitor.value, enable ? 0x01 : 0x00];

  List<int> _xmClockMonitorCommand({required bool enable}) =>
      <int>[XmCommandCode.clockMonitor.value, enable ? 0x01 : 0x00];

  List<int> _xmPingCommand() => <int>[XmCommandCode.ping.value];

  List<int> _xmRequestRadioIdCommand() =>
      <int>[XmCommandCode.requestRadioId.value];

  List<int> _xmExtendedInfoCommand({required int channel}) =>
      <int>[XmCommandCode.requestExtendedInfo.value, channel & 0xFF];

  List<int> _xmLabelMonitorCommand({
    required int channel,
    required bool enable,
  }) {
    final int value = enable ? 0x01 : 0x00;
    return <int>[
      XmCommandCode.channelLabelMonitor.value,
      channel & 0xFF,
      value,
      value,
      value,
      value,
    ];
  }

  List<int> _xmTuneCancelCommand({required int channel}) =>
      <int>[XmCommandCode.tuneCancel.value, channel & 0xFF, 0x00];

  List<int> _xmAudioMuteCommand({required bool mute}) =>
      <int>[XmCommandCode.audioMute.value, mute ? 0x01 : 0x00];

  List<int> _xmVolumeCommand({required int encodedVolume}) =>
      <int>[XmCommandCode.volume.value, encodedVolume & 0xFF];

  List<int> _xmDiagnosticsMonitorCommand({required bool enable}) =>
      <int>[XmCommandCode.diagnosticsMonitor.value, enable ? 0x01 : 0x00];

  List<int> _xmDiagnosticsInfoRequestCommand() =>
      <int>[XmCommandCode.diagnosticsInfoRequest.value, 0x05];

  List<int> _xmChannelInfoCommand({
    required int channel,
    required XmChannelInfoMode mode,
  }) =>
      <int>[
        XmCommandCode.requestChannelInfo.value,
        mode.value,
        channel & 0xFF,
        0x00,
      ];

  List<int> _xmTuneCommand({
    required int target,
    required XmTuneMode mode,
  }) =>
      <int>[
        XmCommandCode.tune.value,
        mode.value,
        target & 0xFF,
        0x00,
        0x00,
        0x01,
      ];

  void _sendCommand(List<int> payload, {bool paced = false}) {
    if (paced) {
      _txChain = _txChain
          .then((_) => Future<void>.delayed(_defaultTxPace))
          .then((_) => _writeCommand(payload))
          .catchError((_) {});
      return;
    }
    unawaited(_writeCommand(payload));
  }

  Future<void> _writeCommand(List<int> payload) async {
    final int length = payload.length;
    final List<int> frame = <int>[
      0x5A,
      0xA5,
      (length >> 8) & 0xFF,
      length & 0xFF,
      ...payload,
      0xED,
      0xED,
    ];
    final Uint8List send = Uint8List.fromList(frame);
    if (FrameTracer.instance.isEnabled) {
      FrameTracer.instance.logTxFrame(send);
    }
    await serialHelper.writeData(send);
  }

  String _hex(List<int> bytes, {int max = 64}) {
    final int take = bytes.length > max ? max : bytes.length;
    final String body = bytes
        .take(take)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    return bytes.length > max ? '$body ...' : body;
  }
}
