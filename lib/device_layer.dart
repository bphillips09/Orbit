// DeviceLayer, handles the raw communication with the device
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/device_message.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_indications.dart';
import 'package:orbit/sxi_payload.dart';
import 'package:orbit/sxi_layer.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/debug_tools_stub.dart'
    if (dart.library.io) 'package:orbit/debug_tools.dart';

class DeviceLayer {
  // Handshake and heartbeat timing
  static const Duration deviceResponseTimeout = Duration(seconds: 10);
  static const Duration heartbeatInterval = Duration(seconds: 2);
  static const Duration heartbeatStaleThreshold = Duration(seconds: 10);
  // Buffer management
  static const int maxRxBufferBytes = 4096; // Cap to avoid overflow

  final int baudRate;
  final Object port;
  final SerialTransport transport;
  final SXiLayer _sxiLayer;
  final StreamController<DeviceMessage> _receiveController =
      StreamController<DeviceMessage>.broadcast();
  final SystemConfiguration? systemConfiguration;
  final SerialHelper _serialHelper = SerialHelper();
  final Function(String title, String message,
      {bool snackbar, bool dismissable})? onMessage;
  final Function(String details, bool fatal)? onError;
  final Function(String title, String details)? onConnectionDetailChanged;
  final Function()? onClearMessages;

  int _writeFailureCount = 0;
  int _highestReceivedSequence = 0;
  bool _initialized = false;
  Uint8List _buffer = Uint8List(0);
  Timer? _heartbeatMonitorTimer;
  DateTime? _lastValidMessage;
  Timer? _networkInitRetryTimer;

  DeviceLayer(
    this._sxiLayer,
    this.port,
    this.baudRate, {
    this.transport = SerialTransport.serial,
    this.systemConfiguration,
    this.onMessage,
    this.onError,
    this.onConnectionDetailChanged,
    this.onClearMessages,
  });

  // Read-only stream of device messages
  Stream<DeviceMessage> get messageStream => _receiveController.stream;

  void _updateConnectionDetail(String details,
      {String title = 'Connecting...'}) {
    onConnectionDetailChanged?.call(title, details);
  }

  Future<bool> startupSequence() async {
    _initialized = false;
    _sxiLayer.deviceLayer = this;
    _stopHeartbeatMonitor();

    _updateConnectionDetail('Starting...');

    if (!_isNetworkPort()) {
      // If the device has not initialized, we have to connect at 57600 baud
      if (await _attemptInitializationAtBaudRate(57600)) {
        return await _finalizeConnection();
      }

      // If the device has initialized, we can connect at any other supported baud
      final int desiredSecondaryBaud = _sxiLayer.appState.secondaryBaudRate;
      if (await _attemptConnectionAtBaudRate(desiredSecondaryBaud)) {
        return await _finalizeConnection(anyDeviceMessage: true);
      }
    } else {
      // For UART-over-IP, open once at the network init baud (57600)
      const int networkInitBaud = 57600;
      _updateConnectionDetail('Connecting over network...');
      if (!await _serialHelper.openPort(
        port,
        networkInitBaud,
        transport: transport,
      )) {
        onError?.call('Failed to open $port at $baudRate baud', false);
        return false;
      }

      _serialHelper.readData(_processData, (error, expectedClosure) {
        if (!expectedClosure) {
          _initialized = false;
          onError?.call(error.toString(), true);
          _stopHeartbeatMonitor();
        }
      });

      // Issue a second CONFIG to the UART-over-IP backend
      try {
        final dynamic helper = _serialHelper;
        final ok = await helper.configureNetworkUartBaud(57600);
        logger.i('Network UART CONFIG result: $ok');
      } catch (_) {}

      // Send init and retry at 500ms intervals until any response arrives
      await sendInitPayload();
      logger.i('Waiting for device response...');
      _networkInitRetryTimer?.cancel();
      _networkInitRetryTimer =
          Timer.periodic(const Duration(milliseconds: 500), (_) async {
        try {
          await sendInitPayload();
        } catch (_) {}
      });

      final gotResponse = await _waitForMessage(anyDeviceMessage: true);
      _networkInitRetryTimer?.cancel();
      _networkInitRetryTimer = null;

      if (gotResponse) {
        // Switch backend UART to the desired secondary baud
        await _switchNetworkBackendBaudIfNeeded();
        return await _finalizeConnection(anyDeviceMessage: true);
      }

      onError?.call('Device did not respond in time.', false);
      await _serialHelper.closePort();
      return false;
    }

    onError?.call('Failed to Connect to Device', true);
    _stopHeartbeatMonitor();
    return false;
  }

  bool _isNetworkPort() {
    return transport == SerialTransport.network;
  }

  Future<void> _switchNetworkBackendBaudIfNeeded() async {
    try {
      if (!_isNetworkPort()) return;

      final int desiredSecondaryBaud = _sxiLayer.appState.secondaryBaudRate;
      if (desiredSecondaryBaud == 57600) return;
      final dynamic helper = _serialHelper;
      final bool ok =
          await helper.configureNetworkUartBaud(desiredSecondaryBaud);
      logger.i('Network UART CONFIG to $desiredSecondaryBaud result: $ok');
      if (ok) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } catch (e) {
      logger.w('Failed to switch network backend baud: $e');
    }
  }

  // Attempt to initialize the device at a given baud rate
  Future<bool> _attemptInitializationAtBaudRate(int baudRate) async {
    _updateConnectionDetail('Initializing...');

    if (!await _serialHelper.openPort(port, baudRate, transport: transport)) {
      onError?.call('Failed to open $port at $baudRate baud', false);
      return false;
    }

    _serialHelper.readData(_processData, (error, expectedClosure) {
      if (!expectedClosure) {
        _initialized = false;
        onError?.call(error.toString(), true);
        _stopHeartbeatMonitor();
      }
    });

    _updateConnectionDetail('Sending init to device...');
    await sendInitPayload();

    // Wait for the device to respond to the init payload
    // If it does, switch to preferred secondary baud
    if (await _waitForMessage()) {
      final int desiredSecondaryBaud = _sxiLayer.appState.secondaryBaudRate;
      return await switchBaudRate(desiredSecondaryBaud);
    }

    _updateConnectionDetail('Closing connection...', title: 'Initialized');
    await _serialHelper.closePort();
    return false;
  }

  // Attempt to connect to the device at a given baud rate
  Future<bool> _attemptConnectionAtBaudRate(int baudRate) async {
    _updateConnectionDetail(
        'Starting secondary connection at $baudRate baud...');

    if (!await _serialHelper.openPort(port, baudRate, transport: transport)) {
      onError?.call('Failed to open $port at $baudRate baud', false);
      return false;
    }

    _serialHelper.readData(_processData, (error, expectedClosure) {
      if (!expectedClosure) {
        _initialized = false;
        onError?.call(error.toString(), true);
        _stopHeartbeatMonitor();
      }
    });

    if (await _waitForMessage(anyDeviceMessage: true)) {
      return true;
    }

    onError?.call('Device did not respond in time.', false);
    await _serialHelper.closePort();
    return false;
  }

  // Finalize the connection
  Future<bool> _finalizeConnection({bool anyDeviceMessage = false}) async {
    _updateConnectionDetail('Finalizing Connection...');
    // If we've already received a device message, don't wait again
    if (!anyDeviceMessage) {
      if (!await _waitForMessage(anyDeviceMessage: false)) {
        return false;
      }
    }

    // Send the config payload, which finishes the boot-up sequence
    sendConfigPayload();

    // Re-apply monitored data services selection if any
    try {
      final selected = _sxiLayer.appState.monitoredDataServices;
      for (final d in selected) {
        final cfgCmd = SXiMonitorDataServiceCommand(
          DataServiceMonitorUpdateType.startMonitorForService,
          d,
        );
        sendControlCommand(cfgCmd);
      }
    } catch (_) {}

    _startHeartbeatMonitor();
    return true;
  }

  // Any valid device message unblocks the wait
  Future<bool> _waitForMessage({bool anyDeviceMessage = false}) async {
    _updateConnectionDetail('Waiting for device to respond...');

    const timeout = deviceResponseTimeout;
    final completer = Completer<bool>();

    Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    StreamSubscription? listener;
    listener = _receiveController.stream.listen((message) {
      if (anyDeviceMessage ||
          message.isInitMessage() ||
          message.payload.runtimeType == HeartbeatPayload) {
        // Heartbeat received, now we're just waiting for playback info
        logger.i('First device response: $message');
        _updateConnectionDetail('Loading Data...', title: 'Connected');
        _initialized = true;
        _lastValidMessage = DateTime.now();

        if (!completer.isCompleted) {
          completer.complete(true);
        }

        listener!.cancel();
      }
    });

    return completer.future;
  }

  // Start the heartbeat monitor
  void _startHeartbeatMonitor() {
    _heartbeatMonitorTimer?.cancel();
    _heartbeatMonitorTimer = Timer.periodic(heartbeatInterval, (timer) {
      if (_lastValidMessage == null ||
          DateTime.now().difference(_lastValidMessage!) >
              heartbeatStaleThreshold) {
        _serialHelper.closePort();
        timer.cancel();
        logger.w('No heartbeat received in the last 10 seconds');
        onError?.call('Error communicating with the device.', true);
      }
    });
  }

  // Stop the heartbeat monitor
  void _stopHeartbeatMonitor() {
    _heartbeatMonitorTimer?.cancel();
    _heartbeatMonitorTimer = null;
  }

  // Process the raw data from the device
  void _processData(Uint8List data) {
    // Append raw bytes and trace if enabled
    if (FrameTracer.instance.isEnabled) {
      // We write the raw RX chunk; complete frames are logged below
      FrameTracer.instance.logRxFrame(data);
    }

    // Treat any received bytes as heartbeat
    _lastValidMessage = DateTime.now();
    _buffer = Uint8List.fromList(_buffer + data);

    // Limit the buffer size to prevent overflow
    if (_buffer.length > maxRxBufferBytes) {
      logger.w('Buffer too large, resetting.');
      logger.i('Buffer: ${_buffer.length} bytes');
      logger.i('Buffer Sample: ${_buffer.take(50).toList()}');
      _buffer = Uint8List(0);
      return;
    }

    while (_buffer.length >= 8) {
      if (!(_buffer[0] == 0xDE && _buffer[1] == 0xC6)) {
        // Resync to next sync marker if present, otherwise drop one byte
        int next = -1;
        for (int i = 1; i + 1 < _buffer.length; i++) {
          if (_buffer[i] == 0xDE && _buffer[i + 1] == 0xC6) {
            next = i;
            break;
          }
        }
        _buffer = next >= 0 ? _buffer.sublist(next) : _buffer.sublist(1);
        continue;
      }

      // Drop leading two bytes if we see duplicate sync right after sync
      if (_buffer.length >= 4 && _buffer[2] == 0xDE && _buffer[3] == 0xC6) {
        _buffer = _buffer.sublist(2);
        continue;
      }

      if (_buffer.length < 6) break; // Wait for header

      final payloadLength = bitCombine(_buffer[4], _buffer[5]);
      // Frame length is always header(6) + payload(len) + checksum(2) = 8 + len
      final frameLength = 8 + payloadLength;
      if (_buffer.length < frameLength) break;

      final frame = _buffer.sublist(0, frameLength);
      if (FrameTracer.instance.isEnabled) {
        FrameTracer.instance.logRxFrame(frame);
      }

      if (validateChecksum(frame)) {
        try {
          final message = DeviceMessage.fromBytes(frame);
          _receiveController.add(message);

          if (message.payload.runtimeType == SXiSubscriptionStatusIndication ||
              message.payload.runtimeType == SXiAuthenticationIndication) {
            logger.d(
                'Subscription/auth status indication: ${message.payload.toBytes().map((e) => e.toRadixString(16)).join(' ')}');
          }

          _highestReceivedSequence = message.sequence;
          _sxiLayer.processMessage(message);
          _lastValidMessage = DateTime.now();
        } catch (e) {
          logger.w('Error parsing DeviceMessage: $e');
          logger.d('Frame Sample: ${frame.take(30).toList()}');
          forceAck(frame[6], frame[7], frame[8], frame[2], frame);
        }
        _buffer = _buffer.sublist(frameLength);
        continue;
      }

      // Resync to next sync marker if checksum fails, otherwise drop one byte
      int nextSync = -1;
      for (int i = 1; i + 1 < frameLength && i + 1 < _buffer.length; i++) {
        if (_buffer[i] == 0xDE && _buffer[i + 1] == 0xC6) {
          nextSync = i;
          break;
        }
      }
      _buffer = nextSync >= 0 ? _buffer.sublist(nextSync) : _buffer.sublist(1);
    }
  }

  // Validate the checksum of a given frame
  bool validateChecksum(List<int> data) {
    int receivedChecksum =
        bitCombine(data[data.length - 2], data[data.length - 1]);
    int calculatedChecksum =
        calculateChecksum(data.sublist(0, data.length - 2));
    return receivedChecksum == calculatedChecksum;
  }

  // Calculate the checksum of a given frame
  int calculateChecksum(List<int> data) {
    int checkValue = 0;
    for (var byte in data) {
      checkValue =
          ((checkValue + byte) & 0xFF) * 0x100 + (checkValue + byte) + 0x100;
      checkValue = ((checkValue >> 16) ^ checkValue) & 0xFFFF;
    }
    return checkValue;
  }

  // Close the device layer
  Future<void> close() async {
    _buffer = Uint8List(0);
    try {
      await _serialHelper.closePort();
    } catch (_) {}
    await _receiveController.close();
  }

  // Send a command to the device
  DeviceMessage? sendControlCommand(SXiPayload payload) {
    if (!_initialized) {
      onError?.call('Device is not initialized', true);
      return null;
    }

    logger.t('Send Control Command: $payload');

    // Increment the sequence number
    final sequence = incrementSequence();
    final message = DeviceMessage(sequence, PayloadType.control, payload);
    _sxiLayer.txBuffer.add(message);

    // Set the state to send control command
    _sxiLayer.sxiState = SXiState.sendControlCommand;

    // Cycle the state, which will send the frame to the device
    _sxiLayer.cycleState();

    return message;
  }

  // Send a frame to the device
  Future<void> sendFrame(DeviceMessage message) async {
    final frame = message.toBytes();
    var send = Uint8List.fromList(frame);

    if (!message.isAck()) {
      logger.t('TX: $message - ${send.length} bytes');
    }

    // Trace the frame if enabled
    if (FrameTracer.instance.isEnabled) {
      FrameTracer.instance.logTxFrame(send);
    }

    // Write the frame to the device
    if (await _serialHelper.writeData(send) != 0) {
      logger.w('Failed to write data to device');
      // Increment failure count
      _writeFailureCount++;
      if (_writeFailureCount >= 3) {
        onError?.call('Failed to write data to device', true);
        _writeFailureCount = 0;
        await _serialHelper.closePort();
        return;
      }
    }
  }

  // Increment the sequence number
  int incrementSequence() {
    _highestReceivedSequence = (_highestReceivedSequence + 1) % 256;
    return _highestReceivedSequence;
  }

  // Add additional payload to the acknowledgement payload
  void addPayloadToAck(List<int> ackPayload, List<int> additionalPayload) {
    if (ackPayload.length + additionalPayload.length <= 10) {
      ackPayload.addAll(additionalPayload);
    } else {
      onError?.call('Payload ACK failed: Length Exceeded', false);
    }
  }

  // Build an acknowledgement message
  Future<void> buildAck(
      DeviceMessage message, List<int>? additionalPayload) async {
    final int opcodeMsb = message.payload.opcodeMsb;
    final int opcodeLsb = message.payload.opcodeLsb;
    final int transactionID = message.payload.transactionID;
    final int sequence = message.sequence;

    final firstByte = ((opcodeMsb & 0x3F) | 0x40) & 0xFF;
    final secondByte = opcodeLsb & 0xFF;

    // Build the acknowledgement payload
    final ackPayload = [firstByte, secondByte, transactionID];

    // Add the additional acknowledgement payload if we have one
    if (additionalPayload != null) {
      addPayloadToAck(ackPayload, additionalPayload);
    }

    // Create the acknowledgement message
    final ackMessage = DeviceMessage(
      sequence,
      PayloadType.control,
      GenericPayload.fromBytes(ackPayload),
    );

    // Add the acknowledgement message to the TX buffer
    _sxiLayer.txBuffer.add(ackMessage);
  }

  // We couldn't parse the message, so we need to force an acknowledgement
  Future<void> forceAck(int opcodeMsb, int opcodeLsb, int transactionID,
      int sequence, List<int> frame) async {
    // Determine message type from opcode using existing indications map
    final opcode = bitCombine(opcodeMsb, opcodeLsb);
    String messageType = 'Unknown';

    // Check if we have a known indication type
    var constructor = SXiPayload.indications[opcode];
    if (constructor != null) {
      try {
        messageType = constructor.toString();
      } catch (e) {
        messageType = 'Known indication (parse failed)';
      }
    }

    onError?.call('''Force ACK: $sequence [$opcodeMsb $opcodeLsb] $transactionID
        Message Type: $messageType (0x${opcode.toRadixString(16).padLeft(4, '0').toUpperCase()})''',
        false);

    final firstByte = ((opcodeMsb & 0x3F) | 0x40) & 0xFF;
    final secondByte = opcodeLsb & 0xFF;

    final ackPayload = [firstByte, secondByte, transactionID];

    // Build additional acknowledgement payload based on message type
    List<int>? additionalPayload;
    try {
      switch (opcode) {
        case 0x80a0: // SXiStatusIndication
        case 0x8201: // SXiCategoryInfoIndication
          // Need frame[4] (indCode or categoryTypeID) - sublist(4, 5) from payload
          if (frame.length > 10) {
            // 6 bytes header + 3 bytes payload minimum + 2 checksum
            additionalPayload = [
              frame[10]
            ]; // frame[6] + 4 = frame[10] for indCode
          }
          break;
        case 0x8300: // SXiMetadataIndication
        case 0x8281: // SXiChannelInfoIndication
        case 0x8301: // SXiChannelMetadataIndication
        case 0x8303: // SXiLookAheadMetadataIndication
          // Need payload sublist(6, 8) which corresponds to chanIDMsb, chanIDLsb
          if (frame.length > 13) {
            // 6 bytes header + 6 bytes payload minimum + 2 checksum
            additionalPayload = [frame[10], frame[11]]; // chanIDMsb, chanIDLsb
          }
          break;
      }

      if (additionalPayload != null) {
        logger.d(
            'Force ACK: Adding additional payload: $additionalPayload for $messageType');
        addPayloadToAck(ackPayload, additionalPayload);
      }
    } catch (e) {
      logger.w(
          'Force ACK: Error building additional payload for $messageType: $e');
      // Continue with basic acknowledgement if additional payload fails
    }

    final ackMessage = DeviceMessage(
      sequence,
      PayloadType.control,
      GenericPayload.fromBytes(ackPayload),
    );

    _sxiLayer.txBuffer.add(ackMessage);
    _sxiLayer.sxiState = SXiState.sendControlCommand;
    _sxiLayer.cycleState();
  }

  // Send the init payload
  Future<void> sendInitPayload() async {
    logger.d('Sending init payload');
    // Map actual baud to device code
    final int configuredBaud = _sxiLayer.appState.secondaryBaudRate;
    int baud;
    switch (configuredBaud) {
      case 57600:
        baud = 0;
        break;
      case 115200:
        baud = 1;
        break;
      case 230400:
        baud = 2;
        break;
      case 460800:
        baud = 3;
        break;
      case 921600:
        baud = 4;
        break;
      default:
        baud = 3;
        break;
    }
    final initPayload = GenericPayload(0, 0, baud, [0]);

    final message = DeviceMessage(0, PayloadType.init, initPayload);
    await sendFrame(message);
  }

  // Send the module configuration payload
  Future<void> sendConfigPayload() async {
    int volume = systemConfiguration?.volume ?? 0;
    int defaultSid = systemConfiguration?.defaultSid ?? 0;
    List<int> eq = systemConfiguration?.eq ?? List<int>.filled(10, 0);
    List<int> presets = List<int>.filled(20, 1);
    List<int> favoriteSongIDs =
        systemConfiguration?.favoriteSongIDs ?? List<int>.empty();
    List<int> favoriteArtistIDs =
        systemConfiguration?.favoriteArtistIDs ?? List<int>.empty();
    if (systemConfiguration != null) {
      for (int i = 0; i < systemConfiguration!.presets.length; i++) {
        presets[i] = systemConfiguration!.presets[i];
      }
    }

    final List<int> songFavFirst = favoriteSongIDs.take(60).toList();
    final List<int> songFavSecond = favoriteSongIDs.skip(60).take(60).toList();
    final List<int> artistFavFirst = favoriteArtistIDs.take(60).toList();
    final List<int> artistFavSecond =
        favoriteArtistIDs.skip(60).take(60).toList();

    List<SXiPayload> initPayloads = [
      // Standard module config
      SXiConfigureModuleCommand(1, 2, 2, 0, 0, 0, 1, 1, 1, 0, 3, 0),
      // Unlock all channels
      SXiConfigureChannelAttributesCommand(
          ChanAttribCfgChangeType.lockChannel, List.filled(24, 0x0000)),
      // Setup smart favorites
      SXiListChannelAttributesCommand(
          ChanAttribListChangeType.smartFavorite, presets),
      // Setup tunemix
      SXiListChannelAttributesCommand(
          ChanAttribListChangeType.tuneMix1, presets),
      // Tune to default SID
      SXiSelectChannelCommand(ChanSelectionType.tuneUsingSID, defaultSid, 1,
          ChannelAttributes.all(), AudioRoutingType.routeToAudio),
      // Restart song on tune
      SXiConfigureChannelSelectionCommand(
          (systemConfiguration?.tuneStart ?? false)
              ? PlayPoint.auto
              : PlayPoint.live,
          5,
          3,
          1),
      // Set EQ band gain
      SXiAudioEqualizerCommand(eq),
      // Set volume
      SXiAudioVolumeCommand(volume),
      // Unmute audio
      SXiAudioMuteCommand(AudioMuteType.unmute),
      // Report the active package
      SXiPackageCommand(PackageOptionType.report, 0),
      // Setup metadata monitors (stop all active monitors)
      SXiMonitorExtendedMetadataCommand(
          MetadataMonitorType.extendedGlobalMetadata,
          MonitorChangeType.dontMonitorAll,
          List.empty()),
      // Setup channel metadata monitor
      SXiMonitorExtendedMetadataCommand.channelMetadata(
        MetadataMonitorType.extendedChannelMetadataForAllChannels,
        MonitorChangeType.monitor,
        [
          ChannelMetadataIdentifier.channelLongDescription,
          ChannelMetadataIdentifier.similarChannelList,
          ChannelMetadataIdentifier.channelListOrder,
          ChannelMetadataIdentifier.channelShortDescription,
        ],
      ),
      // Setup track metadata monitor
      SXiMonitorExtendedMetadataCommand.trackMetadata(
          MetadataMonitorType.extendedTrackMetadataForAllChannels,
          MonitorChangeType.monitor, [
        TrackMetadataIdentifier.songId,
        TrackMetadataIdentifier.songName,
        TrackMetadataIdentifier.artistId,
        TrackMetadataIdentifier.artistName,
        TrackMetadataIdentifier.currentInfo,
        // TrackMetadataIdentifier.sportBroadcastId,
        // TrackMetadataIdentifier.gameTeamId,
        // TrackMetadataIdentifier.leagueBroadcastId,
        // TrackMetadataIdentifier.trafficCityId,
        TrackMetadataIdentifier.itunesSongId
      ]),
      // Setup favorites monitors (stop all active monitors)
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.songMonitor1),
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.songMonitor2),
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.artistMonitor1),
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.artistMonitor2),
      // Setup favorites monitors (start monitoring song favorites)
      if (songFavFirst.isNotEmpty)
        SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: songFavFirst,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
          monitorSlot: SeekMonitorType.songMonitor1,
        ),
      if (songFavSecond.isNotEmpty)
        SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: songFavSecond,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
          monitorSlot: SeekMonitorType.songMonitor2,
        ),
      // Setup favorites monitors (start monitoring artist favorites)
      if (artistFavFirst.isNotEmpty)
        SXiMonitorSeekCommand.artistMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          artistIDs: artistFavFirst,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
          monitorSlot: SeekMonitorType.artistMonitor1,
        ),
      if (artistFavSecond.isNotEmpty)
        SXiMonitorSeekCommand.artistMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          artistIDs: artistFavSecond,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
          monitorSlot: SeekMonitorType.artistMonitor2,
        ),
      // Setup feature monitors (stop all active monitors)
      SXiMonitorFeatureCommand(MonitorChangeType.dontMonitorAll, List.empty()),
      // Setup feature monitors (start monitoring all)
      SXiMonitorFeatureCommand(MonitorChangeType.monitor, [
        FeatureMonitorType.time,
        FeatureMonitorType.channelInfo,
        FeatureMonitorType.categoryInfo,
        FeatureMonitorType.metadata,
        FeatureMonitorType.storedMetadata
      ]),
      // Setup data monitors (stop all active monitors)
      SXiMonitorDataServiceCommand(
          DataServiceMonitorUpdateType.stopMonitorForAllServices,
          DataServiceIdentifier.none),
      // Setup data monitors (start monitoring album art and channel graphics)
      SXiMonitorDataServiceCommand(
          DataServiceMonitorUpdateType.startMonitorForService,
          DataServiceIdentifier.albumArt),
      SXiMonitorDataServiceCommand(
          DataServiceMonitorUpdateType.startMonitorForService,
          DataServiceIdentifier.channelGraphicsUpdates),
      // Setup status monitors (stop all active monitors)
      SXiMonitorStatusCommand(MonitorChangeType.dontMonitorAll, List.empty()),
      // Setup status monitors (start monitoring signal and antenna status)
      SXiMonitorStatusCommand(MonitorChangeType.monitor, [
        StatusMonitorType.signalAndAntennaStatus,
        StatusMonitorType.audioDecoderBitrate,
        StatusMonitorType.audioPresence
      ]),
      // Set satellite time to UTC
      SXiConfigureTimeCommand(TimeZoneType.utc, DSTType.auto),
    ];

    // Send the module configuration payload in sequence
    for (int i = 0; i < initPayloads.length; i++) {
      Future.delayed(Duration(milliseconds: 500 * i), () {
        sendControlCommand(initPayloads[i]);
      });
    }
  }

  // Switch the baud rate
  Future<bool> switchBaudRate(int newBaudRate) async {
    _updateConnectionDetail('Closing existing connection...');
    await _serialHelper.closePort();

    bool portOpened = false;

    _updateConnectionDetail('Opening new connection at $newBaudRate...');
    if (kIsWeb || kIsWasm) {
      portOpened =
          await _serialHelper.openPort(port, newBaudRate, transport: transport);
    } else {
      portOpened =
          await _serialHelper.openPort(port, newBaudRate, transport: transport);
    }
    if (portOpened) {
      _serialHelper.readData(_processData, (error, expectedClosure) {
        if (!expectedClosure) {
          _initialized = false;
          onError?.call(error.toString(), true);
          _stopHeartbeatMonitor();
        }
      });

      return true;
    } else {
      onError?.call(
          'Unable to open $port at $newBaudRate baud, Unknown Error', false);
      return false;
    }
  }

  void addFavorites(List<int> songIDs, List<int> artistIDs) {
    logger.d('Adding favorites: SongIDs: $songIDs, ArtistIDs: $artistIDs');
    // Split across up to two monitors per type (60 IDs per monitor)
    List<SXiPayload> commands = [];
    if (songIDs.isNotEmpty) {
      final List<int> first = songIDs.take(60).toList();
      final List<int> second = songIDs.skip(60).take(60).toList();
      if (first.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: first,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
        ));
      }
      if (second.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: second,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
          monitorSlot: SeekMonitorType.songMonitor2,
        ));
      }
    }
    if (artistIDs.isNotEmpty) {
      final List<int> first = artistIDs.take(60).toList();
      final List<int> second = artistIDs.skip(60).take(60).toList();
      if (first.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.artistMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          artistIDs: first,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
        ));
      }
      if (second.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand(
          SeekMonitorType.artistMonitor2,
          MonitorChangeType.monitor,
          TrackMetadataIdentifier.artistId,
          second.length,
          4,
          second,
          1,
          [TrackMetadataIdentifier.songName.value],
          SeekControlType.enableSeekEndAndImmediate,
        ));
      }
    }
    if (commands.isEmpty) {
      return;
    }
    for (int i = 0; i < commands.length; i++) {
      Future.delayed(Duration(milliseconds: 500 * i), () {
        sendControlCommand(commands[i]);
      });
    }
  }

  void removeFavorites(List<int> songIDs, List<int> artistIDs) {
    logger.d('Removing favorites: SongIDs: $songIDs, ArtistIDs: $artistIDs');
    // Split removals across up to two monitors per type
    List<SXiPayload> commands = [];
    if (songIDs.isNotEmpty) {
      final List<int> first = songIDs.take(60).toList();
      final List<int> second = songIDs.skip(60).take(60).toList();
      if (first.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: first,
          seekControl: SeekControlType.disable,
        ));
      }
      if (second.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: second,
          seekControl: SeekControlType.disable,
          monitorSlot: SeekMonitorType.songMonitor2,
        ));
      }
    }
    if (artistIDs.isNotEmpty) {
      final List<int> first = artistIDs.take(60).toList();
      final List<int> second = artistIDs.skip(60).take(60).toList();
      if (first.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.artistMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          artistIDs: first,
          seekControl: SeekControlType.disable,
        ));
      }
      if (second.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand(
          SeekMonitorType.artistMonitor2,
          MonitorChangeType.monitor,
          TrackMetadataIdentifier.artistId,
          second.length,
          4,
          second,
          1,
          [TrackMetadataIdentifier.songName.value],
          SeekControlType.disable,
        ));
      }
    }
    if (commands.isEmpty) {
      return;
    }
    for (int i = 0; i < commands.length; i++) {
      Future.delayed(Duration(milliseconds: 500 * i), () {
        sendControlCommand(commands[i]);
      });
    }
  }

  void sendFavorites(List<int> songIDs, List<int> artistIDs) {
    logger.d('Sending favorites: SongIDs: $songIDs, ArtistIDs: $artistIDs');
    List<SXiPayload> commands = [
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.songMonitor1),
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.songMonitor2),
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.artistMonitor1),
      SXiMonitorSeekCommand.disableAll(
          seekMonitorID: SeekMonitorType.artistMonitor2),
    ];

    // Songs split across up to two batches
    if (songIDs.isNotEmpty) {
      final List<int> first = songIDs.take(60).toList();
      final List<int> second = songIDs.skip(60).take(60).toList();
      if (first.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: first,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
        ));
      }
      if (second.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.songMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          songIDs: second,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
          monitorSlot: SeekMonitorType.songMonitor2,
        ));
      }
    }

    // Artists split across up to two batches
    if (artistIDs.isNotEmpty) {
      final List<int> first = artistIDs.take(60).toList();
      final List<int> second = artistIDs.skip(60).take(60).toList();
      if (first.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand.artistMonitor(
          monitorChangeType: MonitorChangeType.monitor,
          artistIDs: first,
          seekControl: SeekControlType.enableSeekEndAndImmediate,
        ));
      }
      if (second.isNotEmpty) {
        commands.add(SXiMonitorSeekCommand(
          SeekMonitorType.artistMonitor2,
          MonitorChangeType.monitor,
          TrackMetadataIdentifier.artistId,
          second.length,
          4,
          second,
          1,
          [TrackMetadataIdentifier.songName.value],
          SeekControlType.enableSeekEndAndImmediate,
        ));
      }
    }

    if (commands.isEmpty) {
      return;
    }
    for (int i = 0; i < commands.length; i++) {
      Future.delayed(Duration(milliseconds: 500 * i), () {
        sendControlCommand(commands[i]);
      });
    }
  }
}

// Local system configuration
class SystemConfiguration {
  int volume = 0;
  int defaultSid = 0;
  List<int> eq;
  List<int> presets;
  List<int> favoriteSongIDs;
  List<int> favoriteArtistIDs;
  bool tuneStart;

  SystemConfiguration(
      {this.volume = 0,
      this.defaultSid = 0,
      this.eq = const [],
      this.presets = const [],
      this.favoriteSongIDs = const [],
      this.favoriteArtistIDs = const [],
      this.tuneStart = false});
}
