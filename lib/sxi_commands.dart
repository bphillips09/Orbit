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

class SXiAudioToneBassAndTrebleCommand extends SXiPayload {
  int bass;
  int treble;

  SXiAudioToneBassAndTrebleCommand(this.bass, this.treble)
      : super(0x01, 0x02, 0);

  @override
  List<int> getParameters() {
    treble = treble.clamp(-12, 12);
    bass = bass.clamp(-12, 12);

    return [signedToUnsigned(bass), signedToUnsigned(treble)];
  }
}

class SXiAudioToneGenerateCommand extends SXiPayload {
  int frequencyHz;
  AudioLeftRightType leftRight;
  AudioAlertType alert;
  int volume;

  SXiAudioToneGenerateCommand(
      this.frequencyHz, this.leftRight, this.alert, this.volume)
      : super(0x01, 0x80, 0);

  @override
  List<int> getParameters() {
    int freqParam = frequencyHz ~/ 100;
    freqParam = freqParam.clamp(1, 200);

    int flags = leftRight.value | alert.value;

    int vol = volume;
    vol = vol.clamp(-26, 16);

    return [freqParam, flags, signedToUnsigned(vol)];
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
    // Cap maximum counts (60 values, 32 report tags)
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

class SXiDeviceAuthenticationCommand extends SXiPayload {
  // No parameters

  SXiDeviceAuthenticationCommand() : super(0x00, 0xF1, 0);

  @override
  List<int> getParameters() {
    return [];
  }
}

class SXiDeviceIPAuthenticationCommand extends SXiPayload {
  List<int> challenge;

  SXiDeviceIPAuthenticationCommand(this.challenge) : super(0x00, 0xF0, 0);

  @override
  List<int> getParameters() {
    return [...challenge];
  }
}

class SXiPingCommand extends SXiPayload {
  SXiPingCommand() : super(0x00, 0xE0, 0);

  @override
  List<int> getParameters() {
    return [];
  }
}

class SXiDebugCommand extends SXiPayload {
  final int b0;
  final int b1;
  final int b2;
  final int b3;

  SXiDebugCommand({int b0 = 0, int b1 = 0, int b2 = 0, int b3 = 0})
      : b0 = b0 & 0xFF,
        b1 = b1 & 0xFF,
        b2 = b2 & 0xFF,
        b3 = b3 & 0xFF,
        super(0x0F, 0x09, 0);

  @override
  List<int> getParameters() {
    return [b0, b1, b2, b3];
  }
}

class SXiDebugResetCommand extends SXiPayload {
  SXiDebugResetCommand() : super(0x0F, 0x00, 0);

  @override
  List<int> getParameters() {
    return [0x00, 0x00];
  }
}

class SXiDebugMonitorCommand extends SXiPayload {
  final int bank;
  final int widthType;
  final int address;
  final int length;
  final int flags;
  final int extra;

  SXiDebugMonitorCommand({
    required this.bank,
    required this.widthType,
    required this.address,
    required this.length,
    this.flags = 0,
    this.extra = 0,
  }) : super(0x0F, 0x04, 0);

  SXiDebugMonitorCommand.readByte(int address, {int bank = 0})
      : this(
          bank: bank,
          widthType: 0,
          address: address,
          length: 1,
        );

  @override
  List<int> getParameters() {
    return [
      bank & 0xFF,
      widthType & 0xFF,
      (address >> 24) & 0xFF,
      (address >> 16) & 0xFF,
      (address >> 8) & 0xFF,
      address & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
      flags & 0xFF,
      (extra >> 8) & 0xFF,
      extra & 0xFF,
    ];
  }
}

class SXiDebugWriteBytesCommand extends SXiPayload {
  final int bank;
  final int address;
  final List<int> data;

  static const int _widthType = 0;

  SXiDebugWriteBytesCommand({
    required this.bank,
    required this.address,
    required List<int> data,
  })  : data = List<int>.from(data.map((b) => b & 0xFF)),
        super(0x0F, 0x03, 0);

  @override
  List<int> getParameters() {
    final int length = data.length & 0xFFFF;
    return [
      bank & 0xFF,
      _widthType & 0xFF,
      (address >> 24) & 0xFF,
      (address >> 16) & 0xFF,
      (address >> 8) & 0xFF,
      address & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
      _widthType & 0xFF,
      ...data,
    ];
  }
}

class SXiDebugWriteWordsCommand extends SXiPayload {
  final int bank;
  final int address;
  final List<int> words;

  static const int _widthType = 1;

  SXiDebugWriteWordsCommand({
    required this.bank,
    required this.address,
    required List<int> words,
  })  : words = List<int>.from(words.map((v) => v & 0xFFFF)),
        super(0x0F, 0x03, 0);

  @override
  List<int> getParameters() {
    final int length = words.length & 0xFFFF;
    final List<int> encoded = <int>[];
    for (final w in words) {
      encoded.add((w >> 8) & 0xFF);
      encoded.add(w & 0xFF);
    }
    return [
      bank & 0xFF,
      _widthType & 0xFF,
      (address >> 24) & 0xFF,
      (address >> 16) & 0xFF,
      (address >> 8) & 0xFF,
      address & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
      _widthType & 0xFF,
      ...encoded,
    ];
  }
}

class SXiDebugWriteDWordsCommand extends SXiPayload {
  final int bank;
  final int address;
  final List<int> dwords;

  static const int _widthType = 2;

  SXiDebugWriteDWordsCommand({
    required this.bank,
    required this.address,
    required List<int> dwords,
  })  : dwords = List<int>.from(dwords.map((v) => v & 0xFFFFFFFF)),
        super(0x0F, 0x03, 0);

  @override
  List<int> getParameters() {
    final int length = dwords.length & 0xFFFF;
    final List<int> encoded = <int>[];
    for (final v in dwords) {
      encoded.add((v >> 24) & 0xFF);
      encoded.add((v >> 16) & 0xFF);
      encoded.add((v >> 8) & 0xFF);
      encoded.add(v & 0xFF);
    }
    return [
      bank & 0xFF,
      _widthType & 0xFF,
      (address >> 24) & 0xFF,
      (address >> 16) & 0xFF,
      (address >> 8) & 0xFF,
      address & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
      _widthType & 0xFF,
      ...encoded,
    ];
  }
}

class SXiDebugTunnelCommand extends SXiPayload {
  final int bank;
  final List<int> data;

  SXiDebugTunnelCommand({int bank = 0, required List<int> data})
      : bank = bank & 0xFF,
        data = List<int>.from(data.map((b) => b & 0xFF)),
        super(0x0F, 0x07, 0);

  @override
  List<int> getParameters() {
    final int len = data.length & 0xFFFF;
    return [
      bank,
      (len >> 8) & 0xFF,
      len & 0xFF,
      ...data,
    ];
  }
}

class SXiDebugActivateCommand extends SXiPayload {
  final int id;
  final int param;
  final String name;
  final int reserved;

  SXiDebugActivateCommand({
    required int id,
    required int param,
    required this.name,
    int reserved = 0,
  })  : id = id & 0xFF,
        param = param & 0xFFFF,
        reserved = reserved & 0xFF,
        super(0x0E, 0xC0, 0);

  @override
  List<int> getParameters() {
    final List<int> s = name.codeUnits + [0x00];
    return [
      id,
      reserved,
      (param >> 8) & 0xFF,
      param & 0xFF,
      ...s,
    ];
  }
}

class SXiDebugUnmonitorCommand extends SXiPayload {
  SXiDebugUnmonitorCommand() : super(0x0F, 0x05, 0);

  @override
  List<int> getParameters() {
    return [0x00, 0x00];
  }
}
