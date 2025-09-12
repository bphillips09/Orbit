// Indications sent by the device using the SXi protocol
import 'dart:typed_data';
import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/metadata/metadata.dart';
import 'package:orbit/sxi_payload.dart';

abstract class SXiIndication extends SXiPayload {
  SXiIndication(super.opcodeMsb, super.opcodeLsb, super.transactionID);

  @override
  List<int> toBytes();
}

// Module configuration indication
class SXiConfigureModuleIndication extends SXiPayload {
  final int indCode;
  final int moduleTypeIDA;
  final int moduleTypeIDB;
  final int moduleTypeIDC;
  final int moduleHWRevA;
  final int moduleHWRevB;
  final int moduleHWRevC;
  final int modSWRevMajor;
  final int modSWRevMinor;
  final int modSWRevInc;
  final int sxiRevMajor;
  final int sxiRevMinor;
  final int sxiRevInc;
  final int bbRevMajor;
  final int bbRevMinor;
  final int bbRevInc;
  final int hDecRevMajor;
  final int hDecRevMinor;
  final int hDecRevInc;
  final int rfRevMajor;
  final int rfRevMinor;
  final int rfRevInc;
  final List<int> capability;
  final int durationOfBuffer;
  final int splRevMajor;
  final int splRevMinor;
  final int splRevInc;
  final int maxSmartFavorites;
  final int maxTuneMix;
  final int maxSportsFlash;
  final int maxTWNow;

  SXiConfigureModuleIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        moduleTypeIDA = frame[4],
        moduleTypeIDB = frame[5],
        moduleTypeIDC = frame[6],
        moduleHWRevA = frame[7],
        moduleHWRevB = frame[8],
        moduleHWRevC = frame[9],
        modSWRevMajor = frame[10],
        modSWRevMinor = frame[11],
        modSWRevInc = frame[12],
        sxiRevMajor = frame[13],
        sxiRevMinor = frame[14],
        sxiRevInc = frame[15],
        bbRevMajor = frame[16],
        bbRevMinor = frame[17],
        bbRevInc = frame[18],
        hDecRevMajor = frame[19],
        hDecRevMinor = frame[20],
        hDecRevInc = frame[21],
        rfRevMajor = frame[22],
        rfRevMinor = frame[23],
        rfRevInc = frame[24],
        capability = frame.sublist(25, 29),
        durationOfBuffer = bitCombine(frame[29], frame[30]),
        splRevMajor = frame[31],
        splRevMinor = frame[32],
        splRevInc = frame[33],
        maxSmartFavorites = frame[34],
        maxTuneMix = frame[35],
        maxSportsFlash = frame[36],
        maxTWNow = frame[37],
        super(frame[0], frame[1], frame[2]);

  @override
  String toString() {
    return '''SXiModuleCfgInd {
  IndCode: $indCode
  Module Type: $moduleTypeIDA.$moduleTypeIDB.$moduleTypeIDC
  Module HW Rev: $moduleHWRevA.$moduleHWRevB.$moduleHWRevC
  Module SW Rev: $modSWRevMajor.$modSWRevMinor.$modSWRevInc
  SXI Rev: $sxiRevMajor.$sxiRevMinor.$sxiRevInc
  Baseband Rev: $bbRevMajor.$bbRevMinor.$bbRevInc
  Hardware Decoder Rev: $hDecRevMajor.$hDecRevMinor.$hDecRevInc
  RF Rev: $rfRevMajor.$rfRevMinor.$rfRevInc
  SPL Rev: $splRevMajor.$splRevMinor.$splRevInc
  Duration of Buffer: ${durationOfBuffer}ms
  Max Smart Favorites: $maxSmartFavorites
  Max TuneMix: $maxTuneMix
  Max Sports Flash: $maxSportsFlash
  Max TrafficWatch: $maxTWNow
}''';
  }

  @override
  List<int> getParameters() {
    return [
      indCode,
      moduleTypeIDA,
      moduleTypeIDB,
      moduleTypeIDC,
      moduleHWRevA,
      moduleHWRevB,
      moduleHWRevC,
      modSWRevMajor,
      modSWRevMinor,
      modSWRevInc,
      sxiRevMajor,
      sxiRevMinor,
      sxiRevInc,
      bbRevMajor,
      bbRevMinor,
      bbRevInc,
      hDecRevMajor,
      hDecRevMinor,
      hDecRevInc,
      rfRevMajor,
      rfRevMinor,
      rfRevInc,
      ...capability,
      (durationOfBuffer >> 8) & 0xFF,
      durationOfBuffer & 0xFF,
      splRevMajor,
      splRevMinor,
      splRevInc,
      maxSmartFavorites,
      maxTuneMix,
      maxSportsFlash,
      maxTWNow,
    ];
  }
}

// Advisory indication
class SXiDisplayAdvisoryIndication extends SXiPayload {
  final int indCode;
  final int chanInfoValid;
  final int chanIDMsb;
  final int chanIDLsb;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;

  SXiDisplayAdvisoryIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanInfoValid = frame[4],
        chanIDMsb = frame[5],
        chanIDLsb = frame[6],
        chanNameShort = SXiPayload.parseNextString(frame, 7),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanInfoValid,
      chanIDMsb,
      chanIDLsb,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
    ];
  }
}

// Channel selected indication
class SXiSelectChannelIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final int catID;
  final int refCatID;
  final Uint8List programID;
  final int chanAttributes;
  final int recordRestrictions;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;
  final List<int> catNameShort;
  final List<int> catNameMedium;
  final List<int> catNameLong;
  final List<int> artistBasic;
  final List<int> songBasic;
  final List<int> artistExtd;
  final List<int> songExtd;
  final List<int> contentInfo;
  final int extChannelMetadataCnt;
  final List<int> cmTagValue;
  final int extTrackMetadataCnt;
  final List<int> tmTagValue;
  final int secondaryIDMsb;
  final int secondaryIDLsb;

  SXiSelectChannelIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        catID = frame[8],
        refCatID = frame[9],
        programID = Uint8List.fromList(frame.sublist(10, 14)),
        chanAttributes = frame[14],
        recordRestrictions = frame[15],
        chanNameShort = SXiPayload.parseNextString(frame, 16),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameShort = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameMedium = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        contentInfo = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        extChannelMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        cmTagValue = readCmiBlockFrom(SXiPayload.nextIndex, frame),
        extTrackMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        tmTagValue = readTmiBlockFrom(SXiPayload.nextIndex, frame),
        secondaryIDMsb = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        secondaryIDLsb = (SXiPayload.nextIndex + 1 < frame.length)
            ? frame[SXiPayload.nextIndex + 1]
            : 0,
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      catID,
      refCatID,
      ...programID,
      chanAttributes,
      recordRestrictions,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
      ...catNameShort,
      ...catNameMedium,
      ...catNameLong,
      ...artistBasic,
      ...songBasic,
      ...artistExtd,
      ...songExtd,
      ...contentInfo,
      extChannelMetadataCnt,
      ...cmTagValue,
      extTrackMetadataCnt,
      ...tmTagValue,
      secondaryIDMsb,
      secondaryIDLsb,
    ];
  }
}

// Subscription status changed indication
class SXiSubscriptionStatusIndication extends SXiPayload {
  final int indCode;
  final List<int> radioID;
  final int subscriptionStatus;
  final int reasonCode;
  final int suspendDay;
  final int suspendMonth;
  final int suspendYear;
  final List<int> reasonText;
  final List<int> phoneNumber;
  final int deviceId;

  SXiSubscriptionStatusIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        radioID = SXiPayload.parseNextString(frame, 4),
        subscriptionStatus = frame[13],
        reasonCode = frame[14],
        suspendDay = frame[15],
        suspendMonth = frame[16],
        suspendYear = frame[17],
        reasonText = SXiPayload.parseNextString(frame, 18),
        phoneNumber = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        deviceId = (() {
          int start = SXiPayload.nextIndex;
          int remaining = frame.length - start;

          if (remaining >= 5 && frame[start] == 0x00) {
            start++;
            remaining--;
          }
          if (start + 3 < frame.length) {
            return (frame[start] << 24) |
                (frame[start + 1] << 16) |
                (frame[start + 2] << 8) |
                (frame[start + 3]);
          }
          return 0;
        })(),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      ...radioID,
      subscriptionStatus,
      reasonCode,
      suspendDay,
      suspendMonth,
      suspendYear,
      ...reasonText,
      ...phoneNumber,
      (deviceId >> 24) & 0xFF,
      (deviceId >> 16) & 0xFF,
      (deviceId >> 8) & 0xFF,
      deviceId & 0xFF,
    ];
  }
}

// Channel info indication
class SXiChannelInfoIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final int chanAttributes;
  final int recordRestrictions;
  final int catID;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;

  SXiChannelInfoIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        chanAttributes = frame[8],
        recordRestrictions = frame[9],
        catID = frame[10],
        chanNameShort = SXiPayload.parseNextString(frame, 11),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      chanAttributes,
      recordRestrictions,
      catID,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
    ];
  }
}

// Category info indication
class SXiCategoryInfoIndication extends SXiPayload {
  final int indCode;
  final int catID;
  final List<int> catNameShort;
  final List<int> catNameMedium;
  final List<int> catNameLong;

  SXiCategoryInfoIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        catID = frame[4],
        catNameShort = SXiPayload.parseNextString(frame, 5),
        catNameMedium = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      catID,
      ...catNameShort,
      ...catNameMedium,
      ...catNameLong,
    ];
  }
}

// Data service status indication
class SXiDataServiceStatusIndication extends SXiPayload {
  final int indCode;
  final int dsiMsb;
  final int dsiLsb;
  final int dataServiceStatus;
  final int dmiCnt;
  final List<int> dmi;

  SXiDataServiceStatusIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        dsiMsb = frame[4],
        dsiLsb = frame[5],
        dataServiceStatus = frame[6],
        dmiCnt = frame[7],
        dmi = frame.sublist(8),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      dsiMsb,
      dsiLsb,
      dataServiceStatus,
      dmiCnt,
      ...dmi,
    ];
  }
}

// Metadata indication
class SXiMetadataIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final Uint8List programID;
  final int recordRestrictions;
  final List<int> artistBasic;
  final List<int> songBasic;
  final List<int> artistExtd;
  final List<int> songExtd;
  final List<int> contentInfo;
  final int extTrackMetadataCnt;
  final List<int> tmTagValue;

  SXiMetadataIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        programID = Uint8List.fromList(frame.sublist(8, 12)),
        recordRestrictions = frame[12],
        artistBasic = SXiPayload.parseNextString(frame, 13),
        songBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        contentInfo = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        extTrackMetadataCnt = frame[SXiPayload.nextIndex],
        tmTagValue = frame[SXiPayload.nextIndex] > 0
            ? frame.sublist(SXiPayload.nextIndex + 1)
            : [],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      ...programID,
      recordRestrictions,
      ...artistBasic,
      ...songBasic,
      ...artistExtd,
      ...songExtd,
      ...contentInfo,
      extTrackMetadataCnt,
      ...tmTagValue,
    ];
  }
}

// Status indication
class SXiStatusIndication extends SXiPayload {
  final int indCode;
  final int statusMonitorItemID;
  final List<int> statusMonitorItemValue;

  SXiStatusIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        statusMonitorItemID = frame[4],
        statusMonitorItemValue = frame.sublist(5),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      statusMonitorItemID,
      ...statusMonitorItemValue,
    ];
  }
}

// Channel metadata indication
class SXiChannelMetadataIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final int extMetadataCnt;
  final List<int> cmTagValue;

  SXiChannelMetadataIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        extMetadataCnt = frame[8],
        cmTagValue = frame[8] > 0 ? frame.sublist(9) : [],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      extMetadataCnt,
      ...cmTagValue,
    ];
  }
}

// Look-ahead metadata indication
class SXiLookAheadMetadataIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final List<int> programID;
  final int extMetadataCnt;
  final List<int> tmTagValue;

  SXiLookAheadMetadataIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        programID = frame.sublist(8, 12),
        extMetadataCnt = frame[12],
        tmTagValue = frame[12] > 0 ? frame.sublist(13) : [],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      ...programID,
      extMetadataCnt,
      ...tmTagValue,
    ];
  }
}

// Seek (favorites match) indication
class SXiSeekIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final int chanAttributes;
  final Uint8List programID;
  final int seekMonitorID;
  final int matchedTmiTag;
  final List<int> matchedTmiValue;
  final int extTrackMetadataCnt;
  final List<int> tmTagValue;

  SXiSeekIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        chanAttributes = frame[8],
        programID = Uint8List.fromList(frame.sublist(9, 13)),
        seekMonitorID = frame[13],
        matchedTmiTag = (frame[14] << 8) | frame[15],
        matchedTmiValue = (() {
          // Choose slice length by tag; preserve 32-bit values when present
          final int valueStart = 16;
          if (valueStart > frame.length) return <int>[];
          final tag = (frame[14] << 8) | frame[15];
          switch (TrackMetadataIdentifier.getByValue(tag)) {
            case TrackMetadataIdentifier.artistId:
              if (valueStart + 3 < frame.length) {
                // Prefer full 4-byte artist ID if present
                return frame.sublist(valueStart, valueStart + 4);
              } else if (valueStart + 1 < frame.length) {
                return frame.sublist(valueStart, valueStart + 2);
              }
              return <int>[];
            case TrackMetadataIdentifier.songId:
              if (valueStart + 3 < frame.length) {
                return frame.sublist(valueStart, valueStart + 4);
              }
              return <int>[];
            default:
              final int afterMatchedIndex = advanceOverTmiItems(frame, 14, 1);
              if (afterMatchedIndex <= valueStart ||
                  valueStart > frame.length) {
                return <int>[];
              }
              final int end = afterMatchedIndex.clamp(0, frame.length);
              return frame.sublist(valueStart, end);
          }
        })(),
        extTrackMetadataCnt = (() {
          final int i = advanceOverTmiItems(frame, 14, 1);
          return (i < frame.length) ? frame[i] : 0;
        })(),
        tmTagValue = (() {
          final int i = advanceOverTmiItems(frame, 14, 1);
          return (i < frame.length) ? readTmiBlockFrom(i, frame) : <int>[];
        })(),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    final List<int> matchedHeaderAndValue = [
      (matchedTmiTag >> 8) & 0xFF,
      matchedTmiTag & 0xFF,
      ...matchedTmiValue,
    ];
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      chanAttributes,
      ...programID,
      seekMonitorID,
      ...matchedHeaderAndValue,
      extTrackMetadataCnt,
      ...tmTagValue,
    ];
  }
}

// Instant replay playback information indication
class SXiInstantReplayPlaybackInfoIndication extends SXiPayload {
  final int indCode;
  final int playbackState;
  final int playbackPosition;
  final int playbackIDMsb;
  final int playbackIDLsb;
  final int durationOfTrackMsb;
  final int durationOfTrackLsb;
  final int timeFromStartOfTrackMsb;
  final int timeFromStartOfTrackLsb;
  final int tracksRemainingMsb;
  final int tracksRemainingLsb;
  final int timeRemainingMsb;
  final int timeRemainingLsb;
  final int timeBeforeMsb;
  final int timeBeforeLsb;

  SXiInstantReplayPlaybackInfoIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        playbackState = frame[4],
        playbackPosition = frame[5],
        playbackIDMsb = frame[6],
        playbackIDLsb = frame[7],
        durationOfTrackMsb = frame[8],
        durationOfTrackLsb = frame[9],
        timeFromStartOfTrackMsb = frame[10],
        timeFromStartOfTrackLsb = frame[11],
        tracksRemainingMsb = frame[12],
        tracksRemainingLsb = frame[13],
        timeRemainingMsb = frame[14],
        timeRemainingLsb = frame[15],
        timeBeforeMsb = frame[16],
        timeBeforeLsb = frame[17],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      playbackState,
      playbackPosition,
      playbackIDMsb,
      playbackIDLsb,
      durationOfTrackMsb,
      durationOfTrackLsb,
      timeFromStartOfTrackMsb,
      timeFromStartOfTrackLsb,
      tracksRemainingMsb,
      tracksRemainingLsb,
      timeRemainingMsb,
      timeRemainingLsb,
      timeBeforeMsb,
      timeBeforeLsb
    ];
  }
}

// Instant replay playback metadata indication
class SXiInstantReplayPlaybackMetadataIndication extends SXiPayload {
  final int indCode;
  final int sxmStatus;
  final int playbackIDMsb;
  final int playbackIDLsb;
  final int chanIDMsb;
  final int chanIDLsb;
  final Uint8List programID;
  final int catID;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;
  final List<int> catNameShort;
  final List<int> catNameMedium;
  final List<int> catNameLong;
  final List<int> artistBasic;
  final List<int> songBasic;
  final List<int> artistExtd;
  final List<int> songExtd;
  final List<int> contentInfo;
  final int extChannelMetadataCnt;
  final List<int> cmTagValue;
  final int extTrackMetadataCnt;
  final List<int> tmTagValue;
  final int sidMsb;
  final int sidLsb;

  SXiInstantReplayPlaybackMetadataIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        sxmStatus = frame[4],
        playbackIDMsb = frame[5],
        playbackIDLsb = frame[6],
        chanIDMsb = frame[7],
        chanIDLsb = frame[8],
        programID = Uint8List.fromList(frame.sublist(9, 13)),
        catID = frame[13],
        chanNameShort = SXiPayload.parseNextString(frame, 14),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameShort = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameMedium = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        contentInfo = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        extChannelMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        cmTagValue = (() {
          // If count is zero or out of range, just advance past count byte
          final count = (SXiPayload.nextIndex < frame.length)
              ? frame[SXiPayload.nextIndex]
              : 0;
          int i = SXiPayload.nextIndex + 1;
          final start = i;
          if (count <= 0 || i > frame.length) {
            SXiPayload.nextIndex = SXiPayload.nextIndex + 1;
            return <int>[];
          }

          i = advanceOverCmiItems(frame, i, count);
          SXiPayload.nextIndex = i;
          return (start <= i && start <= frame.length)
              ? frame.sublist(start, i)
              : <int>[];
        })(),
        extTrackMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        tmTagValue = (() {
          final count = (SXiPayload.nextIndex < frame.length)
              ? frame[SXiPayload.nextIndex]
              : 0;
          int i = SXiPayload.nextIndex + 1;
          final start = i;
          if (count <= 0 || i > frame.length) {
            SXiPayload.nextIndex = SXiPayload.nextIndex + 1;
            return <int>[];
          }

          i = advanceOverTmiItems(frame, i, count);
          SXiPayload.nextIndex = i;
          return (start <= i && start <= frame.length)
              ? frame.sublist(start, i)
              : <int>[];
        })(),
        sidMsb = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        sidLsb = (SXiPayload.nextIndex + 1 < frame.length)
            ? frame[SXiPayload.nextIndex + 1]
            : 0,
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      sxmStatus,
      playbackIDMsb,
      playbackIDLsb,
      chanIDMsb,
      chanIDLsb,
      ...programID,
      catID,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
      ...catNameShort,
      ...catNameMedium,
      ...catNameLong,
      ...artistBasic,
      ...songBasic,
      ...artistExtd,
      ...songExtd,
      ...contentInfo,
      extChannelMetadataCnt,
      ...cmTagValue,
      extTrackMetadataCnt,
      ...tmTagValue,
      sidMsb,
      sidLsb,
    ];
  }
}

// Instant replay track recorded information indication
class SXiInstantReplayRecordInfoIndication extends SXiPayload {
  final int indCode;
  final int recordState;
  final int bufferUsage;
  final int newestEntryPlaybackIDMsb;
  final int newestEntryPlaybackIDLsb;
  final int oldestEntryPlaybackIDMsb;
  final int oldestEntryPlaybackIDLsb;
  final int durationOfNewestTrackMsb;
  final int durationOfNewestTrackLsb;
  final int durationOfOldestTrackMsb;
  final int durationOfOldestTrackLsb;

  SXiInstantReplayRecordInfoIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        recordState = frame[4],
        bufferUsage = frame[5],
        newestEntryPlaybackIDMsb = frame[6],
        newestEntryPlaybackIDLsb = frame[7],
        oldestEntryPlaybackIDMsb = frame[8],
        oldestEntryPlaybackIDLsb = frame[9],
        durationOfNewestTrackMsb = frame[10],
        durationOfNewestTrackLsb = frame[11],
        durationOfOldestTrackMsb = frame[12],
        durationOfOldestTrackLsb = frame[13],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      recordState,
      bufferUsage,
      newestEntryPlaybackIDMsb,
      newestEntryPlaybackIDLsb,
      oldestEntryPlaybackIDMsb,
      oldestEntryPlaybackIDLsb,
      durationOfNewestTrackMsb,
      durationOfNewestTrackLsb,
      durationOfOldestTrackMsb,
      durationOfOldestTrackLsb,
    ];
  }
}

// Power mode indication
class SXiPowerModeIndication extends SXiPayload {
  final int indCode;

  SXiPowerModeIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
    ];
  }
}

// Time indication
class SXiTimeIndication extends SXiPayload {
  final int indCode;
  final int minute;
  final int hour;
  final int day;
  final int month;
  final int year;

  SXiTimeIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        minute = frame[4],
        hour = frame[5],
        day = frame[6],
        month = frame[7],
        year = frame[8],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      minute,
      hour,
      day,
      month,
      year,
    ];
  }
}

// Event indication
class SXiEventIndication extends SXiPayload {
  final int eventCode;
  final List<int> eventData;

  SXiEventIndication.fromBytes(List<int> frame)
      : eventCode = frame[3],
        eventData = frame.sublist(4, 24),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      eventCode,
      ...eventData,
    ];
  }
}

// Browse channel indication
class SXiBrowseChannelIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final int catID;
  final int refCatID;
  final List<int> programID;
  final int chanAttributes;
  final int recordRestrictions;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;
  final List<int> catNameShort;
  final List<int> catNameMedium;
  final List<int> catNameLong;
  final List<int> artistBasic;
  final List<int> songBasic;
  final List<int> artistExtd;
  final List<int> songExtd;
  final List<int> contentInfo;
  final int extChannelMetadataCnt;
  final List<int> cmTagValue;
  final int extTrackMetadataCnt;
  final List<int> tmTagValue;

  SXiBrowseChannelIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        catID = frame[8],
        refCatID = frame[9],
        programID = frame.sublist(10, 14),
        chanAttributes = frame[14],
        recordRestrictions = frame[15],
        chanNameShort = SXiPayload.parseNextString(frame, 16),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameShort = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameMedium = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        contentInfo = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        extChannelMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        cmTagValue = readCmiBlockFrom(SXiPayload.nextIndex, frame),
        extTrackMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        tmTagValue = (() {
          final count = (SXiPayload.nextIndex < frame.length)
              ? frame[SXiPayload.nextIndex]
              : 0;
          int i = SXiPayload.nextIndex + 1;
          final start = i;
          if (count <= 0 || i > frame.length) {
            SXiPayload.nextIndex = SXiPayload.nextIndex + 1;
            return <int>[];
          }
          i = advanceOverTmiItems(frame, i, count);
          SXiPayload.nextIndex = i;
          return (start <= i && start <= frame.length)
              ? frame.sublist(start, i)
              : <int>[];
        })(),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      catID,
      refCatID,
      ...programID,
      chanAttributes,
      recordRestrictions,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
      ...catNameShort,
      ...catNameMedium,
      ...catNameLong,
      ...artistBasic,
      ...songBasic,
      ...artistExtd,
      ...songExtd,
      ...contentInfo,
      extChannelMetadataCnt,
      ...cmTagValue,
      extTrackMetadataCnt,
      ...tmTagValue,
    ];
  }
}

// Content buffered indication
class SXiContentBufferedIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final int programIDCnt;
  final int programIDList;
  final int chanAttributes;
  final int flashType;
  final int flashStatus;
  final int flashEventIDMsb;
  final int flashEventIDLsb;
  final List<int> flashEventData;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;

  SXiContentBufferedIndication.fromBytes(List<int> frame)
      : indCode = frame.length > 3 ? frame[3] : 0,
        chanIDMsb = frame.length > 4 ? frame[4] : 0,
        chanIDLsb = frame.length > 5 ? frame[5] : 0,
        sidMsb = frame.length > 6 ? frame[6] : 0,
        sidLsb = frame.length > 7 ? frame[7] : 0,
        programIDCnt = frame.length > 8 ? frame[8] : 0,
        programIDList = frame.length > 9 ? frame[9] : 0,
        chanAttributes = frame.length > 10 ? frame[10] : 0,
        flashType = frame.length > 11 ? frame[11] : 0,
        flashStatus = frame.length > 12 ? frame[12] : 0,
        flashEventIDMsb = frame.length > 13 ? frame[13] : 0,
        flashEventIDLsb = frame.length > 14 ? frame[14] : 0,
        flashEventData =
            frame.length > 18 ? frame.sublist(15, 19) : List.filled(4, 0),
        chanNameShort =
            frame.length > 19 ? SXiPayload.parseNextString(frame, 19) : [],
        chanNameMedium = frame.length > SXiPayload.nextIndex
            ? SXiPayload.parseNextString(frame, SXiPayload.nextIndex)
            : [],
        chanNameLong = frame.length > SXiPayload.nextIndex
            ? SXiPayload.parseNextString(frame, SXiPayload.nextIndex)
            : [],
        super(frame[0], frame[1], frame[2]);

  @override
  String toString() {
    return '''SXiContentBufferedInd {
  IndCode: $indCode
  Channel ID: ${bitCombine(chanIDMsb, chanIDLsb)}
  SID: ${bitCombine(sidMsb, sidLsb)}
  Program ID Count: $programIDCnt
  Program ID List: $programIDList
  Channel Attributes: $chanAttributes
  Flash Type: $flashType
  Flash Status: $flashStatus
  Flash Event ID: ${bitCombine(flashEventIDMsb, flashEventIDLsb)}
  Flash Event Data: ${flashEventData.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}
  Channel Name Short: ${String.fromCharCodes(chanNameShort)}
  Channel Name Medium: ${String.fromCharCodes(chanNameMedium)}
  Channel Name Long: ${String.fromCharCodes(chanNameLong)}
}''';
  }

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      programIDCnt,
      programIDList,
      chanAttributes,
      flashType,
      flashStatus,
      flashEventIDMsb,
      flashEventIDLsb,
      ...flashEventData,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
    ];
  }
}

// Recorded track metadata changed indication
class SXiRecordTrackMetadataIndication extends SXiPayload {
  final int indCode;
  final int sxmStatus;
  final int trackIDMsb;
  final int trackIDLsb;
  final int blockIDMsb;
  final int blockIDLsb;
  final int durationOfTrackMsb;
  final int durationOfTrackLsb;
  final int recordQuality;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final List<int> programID;
  final List<int> radioID;
  final int recordRestrictions;
  final int information;
  final int packetIDMsb;
  final int packetIDLsb;
  final int blPostUPCMsb;
  final int audioEncoderType;
  final int audioBitRate;
  final int catID;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;
  final List<int> catNameShort;
  final List<int> catNameMedium;
  final List<int> catNameLong;
  final List<int> artistBasic;
  final List<int> songBasic;
  final List<int> artistExtd;
  final List<int> songExtd;
  final List<int> contentInfo;
  final int extChannelMetadataCnt;
  final List<int> cmTagValue;
  final int extTrackMetadataCnt;
  final List<int> tmTagValue;

  SXiRecordTrackMetadataIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        sxmStatus = frame[4],
        trackIDMsb = frame[5],
        trackIDLsb = frame[6],
        blockIDMsb = frame[7],
        blockIDLsb = frame[8],
        durationOfTrackMsb = frame[9],
        durationOfTrackLsb = frame[10],
        recordQuality = frame[11],
        chanIDMsb = frame[12],
        chanIDLsb = frame[13],
        sidMsb = frame[14],
        sidLsb = frame[15],
        programID = frame.sublist(16, 20),
        radioID = frame.sublist(20, 29),
        recordRestrictions = frame[29],
        information = frame[30],
        packetIDMsb = frame[31],
        packetIDLsb = frame[32],
        blPostUPCMsb = frame[33],
        audioEncoderType = frame[34],
        audioBitRate = frame[35],
        catID = frame[36],
        chanNameShort = SXiPayload.parseNextString(frame, 37),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameShort = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameMedium = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        contentInfo = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        extChannelMetadataCnt = frame[SXiPayload.nextIndex],
        cmTagValue =
            SXiPayload.parseLengthPrefixedData(frame, SXiPayload.nextIndex),
        extTrackMetadataCnt = frame[SXiPayload.nextIndex],
        tmTagValue =
            SXiPayload.parseLengthPrefixedData(frame, SXiPayload.nextIndex),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      sxmStatus,
      trackIDMsb,
      trackIDLsb,
      blockIDMsb,
      blockIDLsb,
      durationOfTrackMsb,
      durationOfTrackLsb,
      recordQuality,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      ...programID,
      ...radioID,
      recordRestrictions,
      information,
      packetIDMsb,
      packetIDLsb,
      blPostUPCMsb,
      audioEncoderType,
      audioBitRate,
      catID,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
      ...catNameShort,
      ...catNameMedium,
      ...catNameLong,
      ...artistBasic,
      ...songBasic,
      ...artistExtd,
      ...songExtd,
      ...contentInfo,
      extChannelMetadataCnt,
      ...cmTagValue,
      extTrackMetadataCnt,
      ...tmTagValue,
    ];
  }
}

// Package data indication
class SXiPackageIndication extends SXiPayload {
  final int indCode;
  final List<int> radioID;
  final int option;
  final List<int> arrayHash;
  final List<int> pkgMAC;
  final int baseLayerAnteUPCMsb;
  final int baseLayerAnteUPCLsb;
  final int baseLayerPostUPCMsb;
  final int baseLayerPostUPCLsb;
  final int baseLayerDispUPCMsb;
  final int baseLayerDispUPCLsb;
  final int overlayLayerAnteUPCMsb;
  final int overlayLayerAnteUPCLsb;
  final int overlayLayerPostUPCMsb;
  final int overlayLayerPostUPCLsb;
  final int overlayLayerDispUPCMsb;
  final int overlayLayerDispUPCLsb;

  SXiPackageIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        radioID = SXiPayload.parseNextString(frame, 4),
        option = frame[13],
        arrayHash = frame.sublist(14, 26),
        pkgMAC = frame.sublist(26, 38),
        baseLayerAnteUPCMsb = frame[38],
        baseLayerAnteUPCLsb = frame[39],
        baseLayerPostUPCMsb = frame[40],
        baseLayerPostUPCLsb = frame[41],
        baseLayerDispUPCMsb = frame[42],
        baseLayerDispUPCLsb = frame[43],
        overlayLayerAnteUPCMsb = frame[44],
        overlayLayerAnteUPCLsb = frame[45],
        overlayLayerPostUPCMsb = frame[46],
        overlayLayerPostUPCLsb = frame[47],
        overlayLayerDispUPCMsb = frame[48],
        overlayLayerDispUPCLsb = frame[49],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      ...radioID,
      option,
      ...arrayHash,
      ...pkgMAC,
      baseLayerAnteUPCMsb,
      baseLayerAnteUPCLsb,
      baseLayerPostUPCMsb,
      baseLayerPostUPCLsb,
      baseLayerDispUPCMsb,
      baseLayerDispUPCLsb,
      overlayLayerAnteUPCMsb,
      overlayLayerAnteUPCLsb,
      overlayLayerPostUPCMsb,
      overlayLayerPostUPCLsb,
      overlayLayerDispUPCMsb,
      overlayLayerDispUPCLsb,
    ];
  }
}

// Instant replay recorded metadata changed indication
class SXiInstantReplayRecordMetadataIndication extends SXiPayload {
  final int indCode;
  final int sxmStatus;
  final int playbackIDMsb;
  final int playbackIDLsb;
  final int durationOfTrackMsb;
  final int durationOfTrackLsb;
  final int chanIDMsb;
  final int chanIDLsb;
  final List<int> programID;
  final int catID;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;
  final List<int> catNameShort;
  final List<int> catNameMedium;
  final List<int> catNameLong;
  final List<int> artistBasic;
  final List<int> songBasic;
  final List<int> artistExtd;
  final List<int> songExtd;
  final List<int> contentInfo;
  final int extChannelMetadataCnt;
  final List<int> cmTagValue;
  final int extTrackMetadataCnt;
  final List<int> tmTagValue;

  SXiInstantReplayRecordMetadataIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        sxmStatus = frame[4],
        playbackIDMsb = frame[5],
        playbackIDLsb = frame[6],
        durationOfTrackMsb = frame[7],
        durationOfTrackLsb = frame[8],
        chanIDMsb = frame[9],
        chanIDLsb = frame[10],
        programID = frame.sublist(11, 15),
        catID = frame[15],
        chanNameShort = SXiPayload.parseNextString(frame, 16),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameShort = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameMedium = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        catNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songBasic = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        artistExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        songExtd = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        contentInfo = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        extChannelMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        cmTagValue = (() {
          final count = (SXiPayload.nextIndex < frame.length)
              ? frame[SXiPayload.nextIndex]
              : 0;
          int i = SXiPayload.nextIndex + 1;
          final start = i;
          if (count <= 0 || i > frame.length) {
            SXiPayload.nextIndex = SXiPayload.nextIndex + 1;
            return <int>[];
          }
          for (int n = 0; n < count; n++) {
            if (i + 1 >= frame.length) {
              i = frame.length;
              break;
            }
            final tag = (frame[i] << 8) | frame[i + 1];
            i += 2;
            try {
              switch (ChannelMetadataIdentifier.getByValue(tag)) {
                case ChannelMetadataIdentifier.channelShortDescription:
                case ChannelMetadataIdentifier.channelLongDescription:
                  while (i < frame.length && frame[i] != 0) {
                    i++;
                  }
                  if (i < frame.length) i++;
                  break;
                case ChannelMetadataIdentifier.similarChannelList:
                  if (i + 3 >= frame.length) {
                    i = frame.length;
                    break;
                  }
                  int cnt = (frame[i] << 24) |
                      (frame[i + 1] << 16) |
                      (frame[i + 2] << 8) |
                      frame[i + 3];
                  i += 4;
                  int bytesToSkip = cnt * 2;
                  i = (i + bytesToSkip <= frame.length)
                      ? i + bytesToSkip
                      : frame.length;
                  break;
                case ChannelMetadataIdentifier.channelListOrder:
                  if (i + 1 >= frame.length) {
                    i = frame.length;
                    break;
                  }
                  i += 2;
                  break;
              }
            } catch (_) {
              break;
            }
          }
          SXiPayload.nextIndex = i;
          return (start <= i && start <= frame.length)
              ? frame.sublist(start, i)
              : <int>[];
        })(),
        extTrackMetadataCnt = (SXiPayload.nextIndex < frame.length)
            ? frame[SXiPayload.nextIndex]
            : 0,
        tmTagValue = readTmiBlockFrom(SXiPayload.nextIndex, frame),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      sxmStatus,
      playbackIDMsb,
      playbackIDLsb,
      durationOfTrackMsb,
      durationOfTrackLsb,
      chanIDMsb,
      chanIDLsb,
      ...programID,
      catID,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
      ...catNameShort,
      ...catNameMedium,
      ...catNameLong,
      ...artistBasic,
      ...songBasic,
      ...artistExtd,
      ...songExtd,
      ...contentInfo,
      extChannelMetadataCnt,
      ...cmTagValue,
      extTrackMetadataCnt,
      ...tmTagValue,
    ];
  }
}

// Global metadata indication
class SXiGlobalMetadataIndication extends SXiPayload {
  final int indCode;
  final int extMetadataCnt;
  final List<int> gmTagValue;

  SXiGlobalMetadataIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        extMetadataCnt = frame[4],
        gmTagValue = frame[4] > 0 ? frame.sublist(5) : [],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      extMetadataCnt,
      ...gmTagValue,
    ];
  }
}

// Bulletin status indication
class SXiBulletinStatusIndication extends SXiPayload {
  final int indCode;
  final int bulletinType;
  final int bulletinEventIDMsb;
  final int bulletinEventIDLsb;
  final int bulletinParam1Msb;
  final int bulletinParam1Lsb;
  final List<int> flashEventData;
  final int bulletinStatus;

  SXiBulletinStatusIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        bulletinType = frame[4],
        bulletinEventIDMsb = frame[5],
        bulletinEventIDLsb = frame[6],
        bulletinParam1Msb = frame[7],
        bulletinParam1Lsb = frame[8],
        flashEventData = frame.sublist(9, 13),
        bulletinStatus = frame[13],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      bulletinType,
      bulletinEventIDMsb,
      bulletinEventIDLsb,
      bulletinParam1Msb,
      bulletinParam1Lsb,
      ...flashEventData,
      bulletinStatus,
    ];
  }
}

// Flash indication
class SXiFlashIndication extends SXiPayload {
  final int indCode;
  final int chanIDMsb;
  final int chanIDLsb;
  final int sidMsb;
  final int sidLsb;
  final List<int> programID;
  final int chanAttributes;
  final int flashType;
  final int flashStatus;
  final int flashEventIDMsb;
  final int flashEventIDLsb;
  final List<int> flashEventData;
  final List<int> chanNameShort;
  final List<int> chanNameMedium;
  final List<int> chanNameLong;

  SXiFlashIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        chanIDMsb = frame[4],
        chanIDLsb = frame[5],
        sidMsb = frame[6],
        sidLsb = frame[7],
        programID = frame.sublist(8, 12),
        chanAttributes = frame[12],
        flashType = frame[13],
        flashStatus = frame[14],
        flashEventIDMsb = frame[15],
        flashEventIDLsb = frame[16],
        flashEventData = frame.sublist(17, 21),
        chanNameShort = SXiPayload.parseNextString(frame, 21),
        chanNameMedium =
            SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        chanNameLong = SXiPayload.parseNextString(frame, SXiPayload.nextIndex),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      chanIDMsb,
      chanIDLsb,
      sidMsb,
      sidLsb,
      ...programID,
      chanAttributes,
      flashType,
      flashStatus,
      flashEventIDMsb,
      flashEventIDLsb,
      ...flashEventData,
      ...chanNameShort,
      ...chanNameMedium,
      ...chanNameLong,
    ];
  }
}

// Firmware erase indication
class SXiFirmwareEraseIndication extends SXiPayload {
  final int indCode;

  SXiFirmwareEraseIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
    ];
  }
}

// Data packet received indication
class SXiDataPacketIndication extends SXiPayload {
  final DataServiceType packetType;
  final int dmiMsb;
  final int dmiLsb;
  final int packetLenMsb;
  final int packetLenLsb;
  final List<int> dataPacket;

  SXiDataPacketIndication.fromBytes(List<int> frame)
      : packetType = DataServiceType.getByValue(frame[3]),
        dmiMsb = frame[4],
        dmiLsb = frame[5],
        packetLenMsb = frame[6],
        packetLenLsb = frame[7],
        dataPacket = frame.sublist(8),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      packetType.value,
      dmiMsb,
      dmiLsb,
      packetLenMsb,
      packetLenLsb,
      ...dataPacket
    ];
  }
}

class SXiAuthenticationIndication extends SXiPayload {
  final int indCode;
  final List<int> deviceState;

  SXiAuthenticationIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        deviceState = frame.sublist(4),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      ...deviceState,
    ];
  }
}

class SXiIPAuthenticationIndication extends SXiPayload {
  final int indCode;
  final List<int> signedChallenge;

  SXiIPAuthenticationIndication.fromBytes(List<int> frame)
      : indCode = frame[3],
        signedChallenge = frame.sublist(4),
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      indCode,
      ...signedChallenge,
    ];
  }
}

// Error received indication
class SXiErrorIndication extends SXiPayload {
  final int error;

  SXiErrorIndication.fromBytes(List<int> frame)
      : error = frame[3],
        super(frame[0], frame[1], frame[2]);

  @override
  List<int> getParameters() {
    return [
      error,
    ];
  }
}
