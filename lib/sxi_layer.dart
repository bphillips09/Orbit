// SXi layer for the SXi protocol
import 'dart:developer';
import 'dart:collection';
import 'package:orbit/data/sdtp.dart';
import 'package:orbit/data/sdtp_processor.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/metadata/signal_quality.dart';
import 'package:orbit/metadata/metadata.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/sxi_indications.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/device_message.dart';
import 'package:orbit/sxi_payload.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/logging.dart';

class SXiLayer {
  late DeviceLayer deviceLayer;
  SXiState sxiState = SXiState.idle;
  final Queue<DeviceMessage> txBuffer = Queue<DeviceMessage>();
  final Queue<DeviceMessage> rxBuffer = Queue<DeviceMessage>();
  late SDTPProcessor sdtpProcessor;

  final AppState appState;

  SXiLayer(this.appState) {
    sdtpProcessor = SDTPProcessor(this);
  }

  // Set the program image once loaded
  void setProgramImage(int sid, int programId, List<int> image) {
    appState.imageMap.putIfAbsent(sid, () => {});
    final inner = appState.imageMap[sid]!;

    inner[programId] = image;
    appState.setImageForExistingProgram(sid, programId, image);
    final bool isPresetSid = appState.presets.any((p) => p.sid == sid);

    final int perSidLimit = isPresetSid ? 30 : 5;
    while (inner.length > perSidLimit) {
      final int oldestProgramId = inner.keys.first;
      inner.remove(oldestProgramId);
    }
  }

  // Cycle through the SXi active state
  void cycleState() {
    switch (sxiState) {
      case SXiState.idle:
        break;
      case SXiState.sendControlCommand:
        // Send tx buffer
        if (txBuffer.isEmpty) return;
        var nextMessage = txBuffer.first;

        txBuffer.removeFirst();
        deviceLayer.sendFrame(nextMessage);
        break;
      case SXiState.receiveControlMessage:
      case SXiState.receiveDataMessage:
        if (rxBuffer.isEmpty) return;
        var nextMessage = rxBuffer.first;

        if ((nextMessage.payload.opcodeMsb & 0xC0) == 0xC0) {
          rxBuffer.removeFirst();
          processResponse(nextMessage);
        } else if ((nextMessage.payload.opcodeMsb & 0xC0) == 0x80) {
          rxBuffer.removeFirst();
          processIndication(nextMessage);
        } else {
          logger.w(
              'Message in buffer might be unknown OpCode: 0x${nextMessage.payload.opcodeMsb.toRadixString(16)}${nextMessage.payload.opcodeLsb.toRadixString(16)}');
        }
        break;
    }
  }

  // Process a device message
  void processMessage(DeviceMessage message) {
    // Stop processing if it's an init or acknowledgement message
    if ((message.isAck() || message.isInitMessage()) && !message.isError()) {
      return;
    }

    if (message.isError()) {
      var errorIndication = message.payload as SXiErrorIndication;
      showError(SXiError.getByValue(errorIndication.error));
      return;
    }

    // Process the message based on the payload type
    switch (message.payloadType) {
      case PayloadType.init:
        break;
      case PayloadType.control:
        rxBuffer.add(message);
        sxiState = SXiState.receiveControlMessage;
        break;
      case PayloadType.data:
        rxBuffer.add(message);
        sxiState = SXiState.receiveDataMessage;
        break;
      case PayloadType.audio:
        logger.d('Not Processing Audio Payload: ${message.payload}');
        break;
      case PayloadType.debug:
        logger.d('Not Processing Debug Payload: ${message.payload}');
        break;
    }

    // Cycle through the SXi active state
    cycleState();
  }

  // Process a response message from the device
  void processResponse(DeviceMessage message) {
    if (txBuffer.isNotEmpty && txBuffer.first.sequence == message.sequence) {
      switch (message.payloadType) {
        case PayloadType.init:
        case PayloadType.control:
        case PayloadType.debug:
          break;
        case PayloadType.data:
          showError(SXiError.invalid);
          break;
        case PayloadType.audio:
          showError(SXiError.noEntry);
          break;
      }

      sendNextMessage();
    }
  }

  // Process an error message from the device
  void showError(SXiError error) {
    logger.e('SXi error: $error');
    deviceLayer.onMessage?.call('Error', 'SXi Error: $error',
        snackbar: false, dismissable: true);
  }

  // Send the next message in the TX buffer to the device
  void sendNextMessage() {
    if (txBuffer.isEmpty) {
      logger.w('SendNextMessage: TX buffer empty');
      return;
    }

    var nextMessage = txBuffer.first;
    txBuffer.removeFirst();
    deviceLayer.sendFrame(nextMessage);
  }

  // Process an indication message from the device
  void processIndication(DeviceMessage message) {
    List<int>? additionalAckPayload;

    switch (message.payload) {
      case SXiConfigureModuleIndication moduleInfo:
        logger.i('Module boot: ${moduleInfo.toString()}');

        appState.updateModuleConfiguration(
          moduleInfo.moduleTypeIDA,
          moduleInfo.moduleTypeIDB,
          moduleInfo.moduleTypeIDC,
          moduleInfo.moduleHWRevA,
          moduleInfo.moduleHWRevB,
          moduleInfo.moduleHWRevC,
          moduleInfo.modSWRevMajor,
          moduleInfo.modSWRevMinor,
          moduleInfo.modSWRevInc,
          moduleInfo.sxiRevMajor,
          moduleInfo.sxiRevMinor,
          moduleInfo.sxiRevInc,
          moduleInfo.bbRevMajor,
          moduleInfo.bbRevMinor,
          moduleInfo.bbRevInc,
          moduleInfo.hDecRevMajor,
          moduleInfo.hDecRevMinor,
          moduleInfo.hDecRevInc,
          moduleInfo.rfRevMajor,
          moduleInfo.rfRevMinor,
          moduleInfo.rfRevInc,
          moduleInfo.splRevMajor,
          moduleInfo.splRevMinor,
          moduleInfo.splRevInc,
          moduleInfo.durationOfBuffer,
          moduleInfo.maxSmartFavorites,
          moduleInfo.maxTuneMix,
          moduleInfo.maxSportsFlash,
          moduleInfo.maxTWNow,
        );
        break;

      case SXiSubscriptionStatusIndication subscriptionInfo:
        String subscriptionInfoString =
            """<----- SUBSCRIPTION STATUS BEGIN ----->\n
        Ind Code: ${IndicationCode.getByValue(subscriptionInfo.indCode)}
        Subscription Status: ${SubscriptionStatus.getByValue(subscriptionInfo.subscriptionStatus)}
        Reason Code: ${subscriptionInfo.reasonCode}
        Suspend Day: ${subscriptionInfo.suspendDay}
        Suspend Month: ${subscriptionInfo.suspendMonth}
        Suspend Year: ${subscriptionInfo.suspendYear}
        Reason Text: ${String.fromCharCodes(subscriptionInfo.reasonText)}
        Phone Number: ${String.fromCharCodes(subscriptionInfo.phoneNumber)}
        Device ID: ${subscriptionInfo.deviceId}
        <----- SUBSCRIPTION STATUS END ----->""";
        logger.d(subscriptionInfoString);

        appState.updateSubscriptionStatus(
          subscriptionInfo.subscriptionStatus,
          subscriptionInfo.radioID,
          String.fromCharCodes(subscriptionInfo.reasonText),
          String.fromCharCodes(subscriptionInfo.phoneNumber),
        );

        if (subscriptionInfo.deviceId != 0) {
          appState.updateDeviceId(subscriptionInfo.deviceId);
        }

        switch (SubscriptionStatus.getByValue(
            subscriptionInfo.subscriptionStatus)) {
          case SubscriptionStatus.none:
          case SubscriptionStatus.unknown:
            deviceLayer.onMessage?.call(
                'Subscription Updated', 'Subscription Expired',
                snackbar: false, dismissable: true);
            break;
          case SubscriptionStatus.partial:
          case SubscriptionStatus.full:
            deviceLayer.onMessage?.call(
                'Subscription Updated', 'Subscription Activated',
                snackbar: true, dismissable: true);
            break;
        }
        break;

      case SXiContentBufferedIndication bufferedInfo:
        var channel =
            bitCombine(bufferedInfo.chanIDMsb, bufferedInfo.chanIDLsb);
        logger.t("Content Successfully Buffered: $channel");
        break;

      case SXiEventIndication eventIndication:
        final code = EventCode.getByValue(eventIndication.eventCode);
        final dataPairs = <String>[];
        for (int i = 0; i + 1 < eventIndication.eventData.length; i += 2) {
          final a = eventIndication.eventData[i];
          final b = eventIndication.eventData[i + 1];
          dataPairs.add(
              'Event Data ${i.toString().padLeft(2)}:       ${a.toRadixString(16).padLeft(2, '0')} ${b.toRadixString(16).padLeft(2, '0')}');
        }
        final eventString = '''<----- EVENT INDICATION BEGIN ----->\n
        TX ID: ${eventIndication.transactionID}
        Event Code: ${eventIndication.eventCode} (${code.name})
        ${dataPairs.join("\n        ")}
        <----- EVENT INDICATION END ----->''';
        logger.t(eventString);
        break;

      case SXiCategoryInfoIndication categoryInfo:
        appState.addCategory(categoryInfo.catID, categoryInfo.catNameLong);
        logger.t(
            "Update Category: ${categoryInfo.catID} ${String.fromCharCodes(categoryInfo.catNameLong)}");
        break;

      case SXiChannelInfoIndication channelInfo:
        var sid = bitCombine(channelInfo.sidMsb, channelInfo.sidLsb);
        var chan = bitCombine(channelInfo.chanIDMsb, channelInfo.chanIDLsb);

        appState.addChannel(sid, chan,
            String.fromCharCodes(channelInfo.chanNameLong), channelInfo.catID);
        logger.t(
            "Update Station: Channel: $chan, SID: $sid, Name: ${String.fromCharCodes(channelInfo.chanNameLong)}"
            " - ${ChannelAttributes.namesFromMask(channelInfo.chanAttributes)} - ${IndicationCode.getByValue(channelInfo.indCode)}"
            " - ${channelInfo.recordRestrictions}");
        break;

      case SXiSelectChannelIndication channelSelect:
        int sid = bitCombine(channelSelect.sidMsb, channelSelect.sidLsb);
        final channelData = appState.sidMap[sid];

        if (channelSelect.cmTagValue.isNotEmpty) {
          final channelMetadata = getChannelMetadata(channelSelect.cmTagValue);
          int sid = bitCombine(channelSelect.sidMsb, channelSelect.sidLsb);

          if (channelMetadata.shortDescription != null ||
              channelMetadata.longDescription != null) {
            appState.updateChannelDescriptions(
                sid,
                channelMetadata.shortDescription ?? '',
                channelMetadata.longDescription ?? '');
          }
          if (channelMetadata.similarChannels != null) {
            appState.updateSimilarChannels(
                sid, channelMetadata.similarChannels!);
          }
        }

        var indication = IndicationCode.getByValue(channelSelect.indCode);
        appState.isScanActive = indication == IndicationCode.scanNominal;
        appState.isTuneMixActive = indication == IndicationCode.tuneMixNominal;

        if (indication == IndicationCode.noTracks) {
          deviceLayer.onMessage?.call(
              'Warning', 'No tracks available in playlist.',
              snackbar: false, dismissable: true);
        }

        var programIdAsInt = bytesToInt32(channelSelect.programID);

        final bool isLive = appState.playbackState == AppPlaybackState.live;
        appState.updateNowPlayingWithNewData(
          channelSelect.chanNameLong,
          channelSelect.songExtd,
          channelSelect.artistExtd,
          isLive ? (channelData?.airingSongId) : null,
          isLive ? (channelData?.airingArtistId) : null,
          channelSelect.catID,
          bitCombine(channelSelect.chanIDMsb, channelSelect.chanIDLsb),
          bitCombine(channelSelect.sidMsb, channelSelect.sidLsb),
          channelSelect.programID,
          appState.imageMap[sid]?[programIdAsInt] ?? List.empty(),
        );
        break;

      case SXiMetadataIndication metadataUpdate:
        int? nowPlayingSongId;
        int? nowPlayingArtistId;
        int sid = bitCombine(metadataUpdate.sidMsb, metadataUpdate.sidLsb);
        if (metadataUpdate.tmTagValue.isNotEmpty) {
          final trackMetadata = getTrackMetadata(metadataUpdate.tmTagValue);

          nowPlayingSongId = trackMetadata.songId;
          nowPlayingArtistId = trackMetadata.artistId;
        }

        appState.updateNowAiringTrackIdsForSid(sid,
            songId: nowPlayingSongId, artistId: nowPlayingArtistId);

        var channelChanged =
            bitCombine(metadataUpdate.chanIDMsb, metadataUpdate.chanIDLsb);

        var song = String.fromCharCodes(metadataUpdate.songExtd);
        var artist = String.fromCharCodes(metadataUpdate.artistExtd);
        var programIdAsInt = bytesToInt32(metadataUpdate.programID);
        appState.updateChannelData(sid, artist, song, programIdAsInt);

        if (channelChanged == appState.currentChannel) {
          if (appState.playbackState == AppPlaybackState.live) {
            appState.updateNowPlayingWithNewData(
                List.empty(),
                metadataUpdate.songExtd,
                metadataUpdate.artistExtd,
                nowPlayingSongId,
                nowPlayingArtistId,
                -1,
                bitCombine(metadataUpdate.chanIDMsb, metadataUpdate.chanIDLsb),
                bitCombine(metadataUpdate.sidMsb, metadataUpdate.sidLsb),
                metadataUpdate.programID,
                appState.imageMap[sid]?[programIdAsInt] ?? List.empty());
          }

          logger.i('Tuned Channel: Track changed: $song ($nowPlayingSongId) '
              'by $artist ($nowPlayingArtistId)');
        }
        break;

      case SXiInstantReplayPlaybackMetadataIndication playbackMetadataUpdate:
        int? nowPlayingSongId;
        int? nowPlayingArtistId;
        var indication =
            IndicationCode.getByValue(playbackMetadataUpdate.indCode);

        var channelChanged = bitCombine(
            playbackMetadataUpdate.chanIDMsb, playbackMetadataUpdate.chanIDLsb);

        if (playbackMetadataUpdate.tmTagValue.isNotEmpty) {
          final trackMetadata =
              getTrackMetadata(playbackMetadataUpdate.tmTagValue);

          if (trackMetadata.songId != null || trackMetadata.artistId != null) {
            nowPlayingSongId = trackMetadata.songId;
            nowPlayingArtistId = trackMetadata.artistId;
          }
        }

        if (channelChanged == appState.currentChannel ||
            indication == IndicationCode.tuneMixNominal) {
          var programIdAsInt = bytesToInt32(playbackMetadataUpdate.programID);
          var sid = bitCombine(
              playbackMetadataUpdate.sidMsb, playbackMetadataUpdate.sidLsb);
          var song = String.fromCharCodes(playbackMetadataUpdate.songExtd);
          var artist = String.fromCharCodes(playbackMetadataUpdate.artistExtd);

          appState.updateNowPlayingWithNewData(
              playbackMetadataUpdate.chanNameLong,
              playbackMetadataUpdate.songExtd,
              playbackMetadataUpdate.artistExtd,
              nowPlayingSongId,
              nowPlayingArtistId,
              playbackMetadataUpdate.catID,
              bitCombine(playbackMetadataUpdate.chanIDMsb,
                  playbackMetadataUpdate.chanIDLsb),
              bitCombine(
                  playbackMetadataUpdate.sidMsb, playbackMetadataUpdate.sidLsb),
              playbackMetadataUpdate.programID,
              appState.imageMap[sid]?[programIdAsInt] ?? List.empty());

          logger.d('Tuned Channel IR: Track changed: $song ($nowPlayingSongId) '
              'by $artist ($nowPlayingArtistId)');
        }
        break;

      case SXiSeekIndication seekIndication:
        final indication = IndicationCode.getByValue(seekIndication.indCode);
        final sid = bitCombine(seekIndication.sidMsb, seekIndication.sidLsb);
        final channel =
            bitCombine(seekIndication.chanIDMsb, seekIndication.chanIDLsb);

        if (indication != IndicationCode.nominal &&
            indication != IndicationCode.seekEnd) {
          logger.d('Unexpected Seek Match Indication: ${indication.name}');
          break;
        }

        final matchedSeekType =
            TrackMetadataIdentifier.getByValue(seekIndication.matchedTmiTag);

        // Extract matched ID from either direct value or track metadata
        int? matchedId = _extractMatchedId(seekIndication, matchedSeekType);
        if (matchedId == null || matchedId == 0) {
          logger.d('No valid matched ID in Seek Match Indication: $indication');
          break;
        }

        logger.d(
            'Seek Match Indication: $indication on channel: $channel for type: $matchedSeekType');

        // Handle seek events based on indication type and metadata type
        final isSeekStart = indication == IndicationCode.nominal;
        final isSong = matchedSeekType == TrackMetadataIdentifier.songId;
        final isArtist = matchedSeekType == TrackMetadataIdentifier.artistId;

        if (isSeekStart) {
          if (isSong) {
            appState.matchedSongSeekStarted(matchedId, sid, channel);
          } else if (isArtist) {
            appState.matchedArtistSeekStarted(matchedId, sid, channel);
          }
        } else {
          if (isSong) {
            appState.matchedSongSeekEnded(matchedId, sid, channel);
          } else if (isArtist) {
            appState.matchedArtistSeekEnded(matchedId, sid, channel);
          }
        }
        break;

      case SXiStatusIndication statusUpdate:
        var monitorType =
            StatusMonitorType.getByValue(statusUpdate.statusMonitorItemID);
        switch (monitorType) {
          case StatusMonitorType.signalAndAntennaStatus:
            // Signal 0-4
            // Antenna 0 (ok), 1 (no antenna), 2 (shorted), else unknown
            List<int> values = statusUpdate.statusMonitorItemValue;
            if (values.isNotEmpty) {
              bool antennaConnected = true;
              if (values.length > 1 && values[1] == 1) {
                antennaConnected = false;
              }
              appState.updateSignalStatus(values[0], antennaConnected);
            }
            break;
          case StatusMonitorType.audioPresence:
            if (statusUpdate.statusMonitorItemValue.isNotEmpty) {
              appState.updateAudioExpectedStatus(
                  statusUpdate.statusMonitorItemValue[0] == 1);
            }
            break;
          case StatusMonitorType.audioDecoderBitrate:
            if (statusUpdate.statusMonitorItemValue.isNotEmpty) {
              appState.updateAudioDecoderBitrate(
                  statusUpdate.statusMonitorItemValue[0]);
            }
            break;
          case StatusMonitorType.signalQuality:
            try {
              final signalQuality =
                  SignalQuality.fromBytes(statusUpdate.statusMonitorItemValue);
              appState.updateBaseSignalQuality(signalQuality);
            } catch (_) {
              // Ignore
            }
            break;
          case StatusMonitorType.overlaySignalQuality:
            try {
              final overlaySignalQuality = OverlaySignalQuality.fromBytes(
                  statusUpdate.statusMonitorItemValue);
              appState.updateOverlaySignalQualityData(overlaySignalQuality);
            } catch (_) {
              // Ignore
            }
            break;
          case StatusMonitorType.antennaAiming:
            // Theoretically 0 (sat aim), 1 (terr aim) but this doesn't seem to be used
            logger.d(
                'Antenna Aiming Value: ${statusUpdate.statusMonitorItemValue}');
            break;
          case StatusMonitorType.moduleVersion:
          case StatusMonitorType.gpsData:
          case StatusMonitorType.linkInformation:
          case StatusMonitorType.scanAvailableItems:
          default:
            String statusUpdateString = """<----- STATUS UPDATE BEGIN ----->\n
            Monitor Type: ${monitorType.name}
            Indication: ${IndicationCode.getByValue(statusUpdate.indCode)}
            Values: ${statusUpdate.statusMonitorItemValue}
            <----- STATUS UPDATE END ----->""";
            logger.t(statusUpdateString);
            break;
        }
        break;

      case SXiTimeIndication timeInfo:
        logger.d(
            'Time Update: ${timeInfo.month}/${timeInfo.day}/${timeInfo.year} - ${timeInfo.hour}:${timeInfo.minute}');
        appState.updateDeviceTime(timeInfo.minute, timeInfo.hour, timeInfo.day,
            timeInfo.month, timeInfo.year);
        break;

      case SXiInstantReplayRecordInfoIndication recordInfo:
        logger.t(
            '''RecordInfo: Newest Track (${bitCombine(recordInfo.newestEntryPlaybackIDMsb, recordInfo.newestEntryPlaybackIDLsb)}) 
            Duration: ${bitCombine(recordInfo.durationOfNewestTrackMsb, recordInfo.durationOfNewestTrackLsb)} 
            --> Oldest Track (${bitCombine(recordInfo.oldestEntryPlaybackIDMsb, recordInfo.oldestEntryPlaybackIDLsb)}) 
            Duration: ${bitCombine(recordInfo.durationOfOldestTrackMsb, recordInfo.durationOfOldestTrackLsb)}''');
        break;

      case SXiInstantReplayPlaybackInfoIndication playbackInfo:
        var indication = IndicationCode.getByValue(playbackInfo.indCode);
        appState.isTuneMixActive = indication == IndicationCode.tuneMixNominal;

        var id =
            bitCombine(playbackInfo.playbackIDMsb, playbackInfo.playbackIDLsb);
        var position = playbackInfo.playbackPosition;
        var state = playbackInfo.playbackState;
        var duration = bitCombine(
            playbackInfo.durationOfTrackMsb, playbackInfo.durationOfTrackLsb);
        var timeFromStart = bitCombine(playbackInfo.timeFromStartOfTrackMsb,
            playbackInfo.timeFromStartOfTrackLsb);
        var remainingTracks = bitCombine(
            playbackInfo.tracksRemainingMsb, playbackInfo.tracksRemainingLsb);
        var timeRemaining = bitCombine(
            playbackInfo.timeRemainingMsb, playbackInfo.timeRemainingLsb);
        var timeBefore =
            bitCombine(playbackInfo.timeBeforeMsb, playbackInfo.timeBeforeLsb);

        appState.updatePlaybackState(state, id, position, duration,
            timeFromStart, remainingTracks, timeRemaining, timeBefore);
        break;

      case SXiDisplayAdvisoryIndication advisoryInfo:
        var indication = IndicationCode.getByValue(advisoryInfo.indCode);
        if (!indication.toString().contains('nominal')) {
          deviceLayer.onMessage?.call('Channel Warning', indication.name,
              snackbar: false, dismissable: true);
        } else {
          // Clear all messages and warning dialogues when nominal advisory received
          deviceLayer.onClearMessages?.call();
        }

        String advisoryString = """<----- ADVISORY BEGIN ----->\n
        Indication: ${IndicationCode.getByValue(advisoryInfo.indCode)}
        Channel Valid: ${advisoryInfo.chanInfoValid}
        Channel: ${bitCombine(advisoryInfo.chanIDMsb, advisoryInfo.chanIDLsb)}
        Channel Name: ${String.fromCharCodes(advisoryInfo.chanNameLong)}
        <----- ADVISORY END ----->""";
        logger.i(advisoryString);
        break;

      case SXiDataServiceStatusIndication dataServiceStatusInfo:
        var dsi = bitCombine(
            dataServiceStatusInfo.dsiMsb, dataServiceStatusInfo.dsiLsb);
        var dmiList =
            processDMI(dataServiceStatusInfo.dmi, dataServiceStatusInfo.dmiCnt);

        DataServiceIdentifier.addDMI(dsi, dmiList);

        String dataServiceStatusString =
            """<----- DATA SERVICE STATUS BEGIN ----->\n
        Ind Code: ${dataServiceStatusInfo.indCode}
        DSI: $dsi
        DSI String: ${DataServiceIdentifier.getByValue(dsi)}
        Status: ${dataServiceStatusInfo.dataServiceStatus}
        DMI: ${dataServiceStatusInfo.dmiCnt}
        List DMI: $dmiList  
        <----- DATA SERVICE STATUS END ----->""";
        logger.t(dataServiceStatusString);
        break;

      case SXiPackageIndication packageInfo:
        final radioIdStr = String.fromCharCodes(packageInfo.radioID);
        final arrayHashHex = packageInfo.arrayHash
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ')
            .toUpperCase();
        final pkgMacHex = packageInfo.pkgMAC
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ')
            .toUpperCase();

        final blAnteUpc = bitCombine(
            packageInfo.baseLayerAnteUPCMsb, packageInfo.baseLayerAnteUPCLsb);
        final blPostUpc = bitCombine(
            packageInfo.baseLayerPostUPCMsb, packageInfo.baseLayerPostUPCLsb);
        final blDispUpc = bitCombine(
            packageInfo.baseLayerDispUPCMsb, packageInfo.baseLayerDispUPCLsb);
        final olAnteUpc = bitCombine(packageInfo.overlayLayerAnteUPCMsb,
            packageInfo.overlayLayerAnteUPCLsb);
        final olPostUpc = bitCombine(packageInfo.overlayLayerPostUPCMsb,
            packageInfo.overlayLayerPostUPCLsb);
        final olDispUpc = bitCombine(packageInfo.overlayLayerDispUPCMsb,
            packageInfo.overlayLayerDispUPCLsb);

        appState.updateRadioId(packageInfo.radioID);

        String packageString = '<----- PACKAGE BEGIN ----->'
            '\n(Package) Ind Code: ${IndicationCode.getByValue(packageInfo.indCode)}'
            '\n(Package) Radio ID: $radioIdStr'
            '\n(Package) Option: ${PackageOptionType.getByValue(packageInfo.option)}'
            '\n(Package) Array Hash: $arrayHashHex'
            '\n(Package) Pkg MAC: $pkgMacHex'
            '\n(Package) BL Ante UPC: $blAnteUpc'
            '\n(Package) BL Post UPC: $blPostUpc'
            '\n(Package) BL Disp UPC: $blDispUpc'
            '\n(Package) OL Ante UPC: $olAnteUpc'
            '\n(Package) OL Post UPC: $olPostUpc'
            '\n(Package) OL Disp UPC: $olDispUpc'
            '\n<----- PACKAGE END ----->';
        logger.d(packageString);
        break;

      case SXiDataPacketIndication dataPayload:
        var dmi = bitCombine(dataPayload.dmiMsb, dataPayload.dmiLsb);
        var dsi = DataServiceIdentifier.getByDMI(dmi);

        if (dsi == DataServiceIdentifier.none) {
          logger.t('Ignoring unknown DMI: $dmi');
          break;
        }

        var sdtpPacket = SDTPPacket.fromBytes(dataPayload.dataPacket,
            dataPayload.packetLenMsb, dataPayload.packetLenLsb);

        sdtpProcessor.processSDTPPacket(dmi, dsi, sdtpPacket);
        break;

      case SXiInstantReplayRecordMetadataIndication recordedMetadata:
        var indication = IndicationCode.getByValue(recordedMetadata.indCode);

        if (indication == IndicationCode.nominal) {
          var playbackId = bitCombine(
              recordedMetadata.playbackIDMsb, recordedMetadata.playbackIDLsb);
          var duration = bitCombine(recordedMetadata.durationOfTrackMsb,
              recordedMetadata.durationOfTrackLsb);
          var channelId = bitCombine(
              recordedMetadata.chanIDMsb, recordedMetadata.chanIDLsb);
          var songName = String.fromCharCodes(recordedMetadata.songExtd);
          var artistName = String.fromCharCodes(recordedMetadata.artistExtd);

          appState.addChannelPlaybackMetadata(playbackId, channelId,
              recordedMetadata.programID, duration, songName, artistName);
        }

        String recordMetadataString = """<----- RECORD METADATA BEGIN ----->\n
        Ind Code: ${IndicationCode.getByValue(recordedMetadata.indCode)}
        Status: ${recordedMetadata.sxmStatus}
        Playback ID: ${bitCombine(recordedMetadata.playbackIDMsb, recordedMetadata.playbackIDLsb)}
        Duration: ${bitCombine(recordedMetadata.durationOfTrackMsb, recordedMetadata.durationOfTrackLsb)}
        Channel ID: ${bitCombine(recordedMetadata.chanIDMsb, recordedMetadata.chanIDLsb)}
        Program ID: ${bytesToInt32(recordedMetadata.programID)}
        Song Name: ${String.fromCharCodes(recordedMetadata.songExtd)}
        Artist Name: ${String.fromCharCodes(recordedMetadata.artistExtd)}
        <----- RECORD METADATA END ----->""";
        logger.t(recordMetadataString);
        break;

      case SXiChannelMetadataIndication chanMetadata:
        String channelMetadataString = """<----- CHANNEL METADATA BEGIN ----->\n
        Ind Code: ${IndicationCode.getByValue(chanMetadata.indCode)}
        Channel ID: ${bitCombine(chanMetadata.chanIDMsb, chanMetadata.chanIDLsb)}
        SID: ${bitCombine(chanMetadata.sidMsb, chanMetadata.sidLsb)}
        Metadata Length: ${chanMetadata.extMetadataCnt}
        Metadata: ${chanMetadata.cmTagValue}
        <----- CHANNEL METADATA END ----->""";
        logger.t(channelMetadataString);

        if (chanMetadata.cmTagValue.isNotEmpty) {
          final channelMetadata = getChannelMetadata(chanMetadata.cmTagValue);
          int sid = bitCombine(chanMetadata.sidMsb, chanMetadata.sidLsb);

          if (channelMetadata.shortDescription != null ||
              channelMetadata.longDescription != null) {
            appState.updateChannelDescriptions(
                sid,
                channelMetadata.shortDescription ?? '',
                channelMetadata.longDescription ?? '');
          }
          if (channelMetadata.similarChannels != null) {
            appState.updateSimilarChannels(
                sid, channelMetadata.similarChannels!);
          }
        }

        break;

      case SXiGlobalMetadataIndication globalMetadata:
        String globalMetadataString = """<----- GLOBAL METADATA BEGIN ----->\n
        Ind Code: ${IndicationCode.getByValue(globalMetadata.indCode)}
        Metadata Length: ${globalMetadata.extMetadataCnt}
        Metadata: ${globalMetadata.gmTagValue}
        <----- GLOBAL METADATA END ----->""";
        logger.t(globalMetadataString);

        if (globalMetadata.gmTagValue.isNotEmpty) {
          final parsedGlobalMetadata =
              getGlobalMetadata(globalMetadata.gmTagValue);
          for (var item in parsedGlobalMetadata.allItems) {
            logger.t('  $item');
          }
        }

        break;

      case SXiAuthenticationIndication authenticationInfo:
        logger.d('Authentication Device ID: ${authenticationInfo.deviceId}');
        break;

      case SXiIPAuthenticationIndication ipAuthenticationInfo:
        logger.d(
            'IP Authentication Indication: ${ipAuthenticationInfo.signedChallenge}');
        break;

      // Generic payload
      case GenericPayload genericPayload:
        logger.d(
            'Generic Payload opcode: ${genericPayload.opcode.toRadixString(16)}');
        if (appState.debugMode) {
          inspect(message.payload);
        }
        break;

      // Unhandled payload
      default:
        logger.w('Unhandled Payload: ${message.payload.runtimeType}');
        if (appState.debugMode) {
          inspect(message.payload);
        }
        break;
    }

    // Add an additional ack payload if needed for the indication type
    switch (message.payload) {
      case SXiStatusIndication _:
      case SXiCategoryInfoIndication _:
        // Status, category info, and data service status indications
        additionalAckPayload = message.payload.toBytes().sublist(4, 5);
        break;
      case SXiMetadataIndication _:
      case SXiChannelInfoIndication _:
      case SXiChannelMetadataIndication _:
      case SXiLookAheadMetadataIndication _:
        // Metadata, channel info, channel metadata, and look-ahead metadata indications
        additionalAckPayload = message.payload.toBytes().sublist(6, 8);
        break;
    }

    // Build the ack message and cycle the state
    deviceLayer.buildAck(message, additionalAckPayload);
    sxiState = SXiState.sendControlCommand;
    cycleState();
  }

  int? _extractMatchedId(SXiSeekIndication seekIndication,
      TrackMetadataIdentifier matchedSeekType) {
    // Try direct value from matchedTmiValue first (prefer 32-bit when present)
    if (seekIndication.matchedTmiValue.length >= 4) {
      final v = seekIndication.matchedTmiValue;
      final matchedId = (v[0] << 24) | (v[1] << 16) | (v[2] << 8) | (v[3]);
      return matchedId == 0 ? null : matchedId;
    } else if (seekIndication.matchedTmiValue.length >= 2) {
      final matchedId = bitCombine(
          seekIndication.matchedTmiValue[0], seekIndication.matchedTmiValue[1]);
      return matchedId == 0 ? null : matchedId;
    }

    // Fall back to extracting from track metadata
    try {
      final matchedTrackMetadata = getTrackMetadata(seekIndication.tmTagValue);

      return switch (matchedSeekType) {
        TrackMetadataIdentifier.songId => matchedTrackMetadata.songId,
        TrackMetadataIdentifier.artistId => matchedTrackMetadata.artistId,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}

enum SXiState {
  idle,
  sendControlCommand,
  receiveControlMessage,
  receiveDataMessage,
}
