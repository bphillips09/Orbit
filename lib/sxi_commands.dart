// Commands for the SXi protocol
// Mostly self-explanatory
import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_payload.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_indication_types.dart';

class SXiConfigureModuleCommand extends SXiPayload {
  int fade;
  int categoryLabelLength;
  int channelLabelLength;
  int metadataLabelLength;
  int maxPendingIndications;
  int confirmationWaitTime;
  int irControl;
  int irDeleteOnTune;
  int irMarkNewTrack;
  int recordControl;
  int extendedControl;
  int prioritySmartFavCnt;

  SXiConfigureModuleCommand(
      this.fade,
      this.categoryLabelLength,
      this.channelLabelLength,
      this.metadataLabelLength,
      this.maxPendingIndications,
      this.confirmationWaitTime,
      this.irControl,
      this.irDeleteOnTune,
      this.irMarkNewTrack,
      this.recordControl,
      this.extendedControl,
      this.prioritySmartFavCnt)
      : super(0x00, 0x20, 0);

  @override
  List<int> getParameters() {
    return [
      fade,
      categoryLabelLength,
      channelLabelLength,
      metadataLabelLength,
      maxPendingIndications,
      confirmationWaitTime,
      irControl,
      irDeleteOnTune,
      irMarkNewTrack,
      recordControl,
      extendedControl,
      prioritySmartFavCnt,
    ];
  }
}

class SXiMonitorExtendedMetadataCommand extends SXiPayload {
  MetadataMonitorType monitorSelection;
  MonitorChangeType monitorChangeType;
  List<int> emi;

  SXiMonitorExtendedMetadataCommand(
      this.monitorSelection, this.monitorChangeType, this.emi)
      : super(0x00, 0xA2, 0);

  SXiMonitorExtendedMetadataCommand.trackMetadata(
      MetadataMonitorType monitorType,
      MonitorChangeType changeType,
      List<TrackMetadataIdentifier> identifiers)
      : this(monitorType, changeType, identifiers.map((e) => e.value).toList());

  SXiMonitorExtendedMetadataCommand.channelMetadata(
      MetadataMonitorType monitorType,
      MonitorChangeType changeType,
      List<ChannelMetadataIdentifier> identifiers)
      : this(monitorType, changeType, identifiers.map((e) => e.value).toList());

  SXiMonitorExtendedMetadataCommand.globalMetadata(
      MonitorChangeType changeType, List<GlobalMetadataIdentifier> identifiers)
      : this(MetadataMonitorType.extendedGlobalMetadata, changeType,
            identifiers.map((e) => e.value).toList());

  @override
  List<int> getParameters() {
    int count = emi.length;

    // Apply count limits based on analysis
    switch (monitorSelection) {
      case MetadataMonitorType
            .extendedChannelMetadataForActiveAndBrowsedChannels:
      case MetadataMonitorType.extendedChannelMetadataForAllChannels:
        if (count > 31) {
          // 31 max for CMI
          count = 32; // Set to 32 if over limit
        }
        break;
      case MetadataMonitorType.extendedGlobalMetadata:
        if (count > 63) {
          // 63 max for GMI
          count = 64; // Set to 64 if over limit
        }
        break;
      case MetadataMonitorType.extendedTrackMetadataForActiveAndBrowsedChannels:
      case MetadataMonitorType.extendedTrackMetadataForAllChannels:
      case MetadataMonitorType.lookAheadTrackMetadataForAllChannels:
        if (count > 31) {
          // 31 max for TMI
          count = 32; // Set to 32 if over limit
        }
        break;
    }

    List<int> params = [
      monitorSelection.value,
      monitorChangeType.value,
      count,
    ];

    // Add metadata identifiers as 16-bit values (MSB, LSB)
    for (var i = 0; i < count && i < emi.length; i++) {
      int value = emi[i];
      params.add((value >> 8) & 0xFF); // MSB
      params.add(value & 0xFF); // LSB
    }

    return params;
  }
}

class SXiPowerModeCommand extends SXiPayload {
  bool powerOn;

  SXiPowerModeCommand(this.powerOn) : super(0x00, 0x21, 0);

  @override
  List<int> getParameters() {
    return [powerOn ? 1 : 0];
  }
}

class SXiConfigureTimeCommand extends SXiPayload {
  TimeZoneType timeZone;
  DSTType dst;

  SXiConfigureTimeCommand(this.timeZone, this.dst) : super(0x00, 0x60, 0);

  @override
  List<int> getParameters() {
    return [timeZone.value, dst.value];
  }
}

class SXiConfigureChannelAttributesCommand extends SXiPayload {
  ChanAttribCfgChangeType attributeChangeType;
  List<int> sidList;

  SXiConfigureChannelAttributesCommand(this.attributeChangeType, this.sidList)
      : super(0x02, 0x82, 0);

  @override
  List<int> getParameters() {
    return [attributeChangeType.value, ...sidList];
  }
}

class SXiListChannelAttributesCommand extends SXiPayload {
  ChanAttribListChangeType attributeChangeType;
  List<int> sidList;
  SXiListChannelAttributesCommand(this.attributeChangeType, this.sidList)
      : super(0x02, 0x84, 0);

  @override
  List<int> getParameters() {
    var sidListLength = bitSplit(sidList.length);
    var sidBytes = sidList.expand((sid) => [sid >> 8, sid & 0xFF]).toList();
    return [
      attributeChangeType.value,
      sidListLength.$1,
      sidListLength.$2,
      ...sidBytes,
    ];
  }
}

class SXiConfigureChannelSelectionCommand extends SXiPayload {
  PlayPoint playPoint;
  int playSeconds;
  int channelScanInclude;
  int channelScanExclude;

  SXiConfigureChannelSelectionCommand(this.playPoint, this.playSeconds,
      this.channelScanInclude, this.channelScanExclude)
      : super(0x02, 0x83, 0);

  @override
  List<int> getParameters() {
    var chanInclude = bitSplit(channelScanInclude);
    var chanExclude = bitSplit(channelScanExclude);

    return [
      0,
      playPoint.value,
      playSeconds,
      chanInclude.$1,
      chanInclude.$2,
      chanExclude.$1,
      chanExclude.$2,
    ];
  }
}

class SXiSelectChannelCommand extends SXiPayload {
  ChanSelectionType selectionType;
  int channelIDorSID;
  int catID;
  int overrides;
  AudioRoutingType routing;

  SXiSelectChannelCommand(this.selectionType, this.channelIDorSID, this.catID,
      this.overrides, this.routing)
      : super(0x02, 0x80, 0);

  @override
  List<int> getParameters() {
    var channelIdOrSid = bitSplit(channelIDorSID);

    return [
      selectionType.value,
      channelIdOrSid.$1,
      channelIdOrSid.$2,
      catID,
      overrides,
      routing.value,
    ];
  }
}

class SXiAudioEqualizerCommand extends SXiPayload {
  List<int> bandGain;

  SXiAudioEqualizerCommand(this.bandGain) : super(0x01, 0x04, 0);

  @override
  List<int> getParameters() {
    return [...bandGain.map((band) => signedToUnsigned(band))];
  }
}

class SXiAudioExciterCommand extends SXiPayload {
  AudioExciterType enabled;
  int lowShelfGain;
  int highShelfGain;
  int allPassGain;
  int shelvingGain;

  SXiAudioExciterCommand(this.enabled, this.lowShelfGain, this.highShelfGain,
      this.allPassGain, this.shelvingGain)
      : super(0x01, 0x05, 0);

  @override
  List<int> getParameters() {
    return [
      enabled.value,
      signedToUnsigned(lowShelfGain),
      signedToUnsigned(highShelfGain),
      signedToUnsigned(allPassGain),
      signedToUnsigned(shelvingGain),
    ];
  }
}

class SXiAudioMuteCommand extends SXiPayload {
  AudioMuteType mute;

  SXiAudioMuteCommand(this.mute) : super(0x01, 0x00, 0);

  @override
  List<int> getParameters() {
    return [mute.value];
  }
}

class SXiAudioVolumeCommand extends SXiPayload {
  int volume;

  SXiAudioVolumeCommand(this.volume) : super(0x01, 0x01, 0);

  @override
  List<int> getParameters() {
    return [signedToUnsigned(volume)];
  }
}

class SXiMonitorSeekCommand extends SXiPayload {
  SeekMonitorType seekMonitorID;
  MonitorChangeType monitorChangeType;
  TrackMetadataIdentifier monitorTMI;
  int monitorValueCount;
  int monitorValueLength;
  List<int> monitorValues;
  int reportTMICount;
  List<int> reportTMI;
  SeekControlType seekControl;

  SXiMonitorSeekCommand(
    this.seekMonitorID,
    this.monitorChangeType,
    this.monitorTMI,
    this.monitorValueCount,
    this.monitorValueLength,
    this.monitorValues,
    this.reportTMICount,
    this.reportTMI,
    this.seekControl,
  ) : super(0x03, 0x04, 0);

  // Factory constructor for song monitoring
  SXiMonitorSeekCommand.songMonitor({
    required MonitorChangeType monitorChangeType,
    required List<int> songIDs,
    required SeekControlType seekControl,
    SeekMonitorType monitorSlot = SeekMonitorType.songMonitor1,
  }) : this(
          monitorSlot,
          monitorChangeType,
          TrackMetadataIdentifier.songId,
          songIDs.length,
          4,
          songIDs,
          0,
          [],
          seekControl,
        );

  // Factory constructor for artist monitoring
  SXiMonitorSeekCommand.artistMonitor({
    required MonitorChangeType monitorChangeType,
    required List<int> artistIDs,
    required SeekControlType seekControl,
    SeekMonitorType monitorSlot = SeekMonitorType.artistMonitor1,
  }) : this(
          monitorSlot,
          monitorChangeType,
          TrackMetadataIdentifier.artistId,
          artistIDs.length,
          4,
          artistIDs,
          1,
          [TrackMetadataIdentifier.songName.value],
          seekControl,
        );

  // Factory constructor for disabling all monitors
  SXiMonitorSeekCommand.disableAll({
    required SeekMonitorType seekMonitorID,
  }) : this(
          seekMonitorID,
          MonitorChangeType.dontMonitorAll,
          TrackMetadataIdentifier.songId,
          0,
          0,
          [],
          0,
          [],
          SeekControlType.enableSeekEndAndImmediate,
        );

  @override
  List<int> getParameters() {
    // Cap maximum counts to match radio behavior (60 values, 32 report tags)
    const int maxMonitorValues = 60;
    const int maxReportTmis = 32;
    final List<int> valuesToSend = monitorValues.length > maxMonitorValues
        ? monitorValues.take(maxMonitorValues).toList()
        : monitorValues;
    final List<int> reportListToSend = reportTMI.length > maxReportTmis
        ? reportTMI.take(maxReportTmis).toList()
        : reportTMI;

    List<int> params = [
      seekMonitorID.value,
      monitorChangeType.value,
      (monitorTMI.value >> 8) & 0xFF,
      monitorTMI.value & 0xFF,
      valuesToSend.length,
      monitorValueLength,
    ];

    // Add monitor values with byte conversion
    for (int value in valuesToSend) {
      if (monitorValueLength == 4) {
        params.addAll([
          (value >> 24) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 8) & 0xFF,
          value & 0xFF,
        ]);
      } else if (monitorValueLength == 2) {
        params.addAll([
          (value >> 8) & 0xFF,
          value & 0xFF,
        ]);
      } else {
        params.add(value & 0xFF);
      }
    }

    // Report TMI list: write count, then each 16-bit identifier
    params.add(reportListToSend.length);
    for (final tmi in reportListToSend) {
      params.add((tmi >> 8) & 0xFF);
      params.add(tmi & 0xFF);
    }

    params.add(seekControl.value);

    return params;
  }

  @override
  String toString() {
    return 'SXiMonitorSeekCommand(seekMonitorID: $seekMonitorID, monitorChangeType: $monitorChangeType, monitorTMI: $monitorTMI, monitorValueCount: $monitorValueCount, monitorValueLength: $monitorValueLength, monitorValues: $monitorValues, reportTMICount: $reportTMICount, reportTMI: $reportTMI, seekControl: $seekControl)';
  }
}

class SXiMonitorFeatureCommand extends SXiPayload {
  MonitorChangeType monitorOperation;
  List<FeatureMonitorType> featureMonitorIDs;

  SXiMonitorFeatureCommand(this.monitorOperation, this.featureMonitorIDs)
      : super(0x00, 0xA1, 0);

  @override
  List<int> getParameters() {
    return [
      monitorOperation.value,
      featureMonitorIDs.length,
      ...featureMonitorIDs.map((e) => e.value)
    ];
  }
}

class SXiMonitorStatusCommand extends SXiPayload {
  MonitorChangeType monitorChangeType;
  List<StatusMonitorType> statusMonitorItems;

  SXiMonitorStatusCommand(this.monitorChangeType, this.statusMonitorItems)
      : super(0x00, 0xA0, 0);

  @override
  List<int> getParameters() {
    return [
      monitorChangeType.value,
      statusMonitorItems.length,
      ...statusMonitorItems.map((e) => e.value)
    ];
  }
}

class SXiInstantReplayPlaybackControlCommand extends SXiPayload {
  PlaybackControlType control;
  int timeOffset;
  int playbackId;

  SXiInstantReplayPlaybackControlCommand(
      this.control, this.timeOffset, this.playbackId)
      : super(0x04, 0x02, 0);

  @override
  List<int> getParameters() {
    var timeOffsetBitSplit = bitSplit(timeOffset);
    var playbackIdBitSplit = bitSplit(playbackId);

    return [
      control.value,
      timeOffsetBitSplit.$1,
      timeOffsetBitSplit.$2,
      playbackIdBitSplit.$1,
      playbackIdBitSplit.$2
    ];
  }
}

class SXiMonitorDataServiceCommand extends SXiPayload {
  DataServiceMonitorUpdateType updateType;
  DataServiceIdentifier dataType;

  SXiMonitorDataServiceCommand(this.updateType, this.dataType)
      : super(0x05, 0x00, 0);

  @override
  List<int> getParameters() {
    return [
      updateType.value,
      ((dataType.value >> 8) & 0xFF),
      (dataType.value & 0xFF)
    ];
  }
}

class SXiPackageCommand extends SXiPayload {
  late PackageOptionType option;
  late int index;

  SXiPackageCommand(this.option, this.index) : super(0x0E, 0xD0, 0);

  @override
  List<int> getParameters() {
    return [option.value, index];
  }
}

class SXiDeviceIPAuthenticationCommand extends SXiPayload {
  bool enabled;

  SXiDeviceIPAuthenticationCommand(this.enabled) : super(0x00, 0xF0, 0);

  @override
  List<int> getParameters() {
    return [enabled ? 1 : 0];
  }
}

class SXiDeviceAuthenticationCommand extends SXiPayload {
  bool enabled;

  SXiDeviceAuthenticationCommand(this.enabled) : super(0x00, 0xF1, 0);

  @override
  List<int> getParameters() {
    return [enabled ? 1 : 0];
  }
}

class SXiPingCommand extends SXiPayload {
  SXiPingCommand() : super(0x00, 0xE0, 0);

  @override
  List<int> getParameters() {
    return [];
  }
}
