// Command type enums for the SXi protocol
// Mostly self-explanatory
enum DataServiceMonitorUpdateType {
  startMonitorForService(0),
  stopMonitorForService(1),
  stopMonitorForAllServices(2);

  const DataServiceMonitorUpdateType(this.value);
  final int value;

  static DataServiceMonitorUpdateType getByValue(int i) {
    return DataServiceMonitorUpdateType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum DataServiceType {
  sdtp(0),
  xmApp(1),
  rawDataPacket(2);

  const DataServiceType(this.value);
  final int value;

  static DataServiceType getByValue(int i) {
    return DataServiceType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum AudioMuteType {
  unmute(0),
  muteAudio(1),
  muteAudioAndClocks(2);

  const AudioMuteType(this.value);
  final int value;

  static AudioMuteType getByValue(int i) {
    return AudioMuteType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum AudioLeftRightType {
  none(0),
  right(1),
  left(2),
  both(3);

  const AudioLeftRightType(this.value);
  final int value;

  static AudioLeftRightType getByValue(int i) {
    return AudioLeftRightType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum AudioExciterType {
  disable(0),
  enable(1);

  const AudioExciterType(this.value);
  final int value;

  static AudioExciterType getByValue(int i) {
    return AudioExciterType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum AudioAlertType {
  none(0),
  alert1(4),
  alert2(8);

  const AudioAlertType(this.value);
  final int value;

  static AudioAlertType getByValue(int i) {
    return AudioAlertType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum ChanAttribCfgChangeType {
  skipChannel(0),
  lockChannel(1),
  scanExcludeChannel(3);

  const ChanAttribCfgChangeType(this.value);
  final int value;

  static ChanAttribCfgChangeType getByValue(int i) {
    return ChanAttribCfgChangeType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum ChanAttribListChangeType {
  includeInScan(0),
  smartFavorite(1),
  smartFavoriteScan(2),
  sportsFlash(0x20),
  tuneMix1(0x40),
  tuneMix2(0x41),
  tuneMix3(0x42),
  tuneMix4(0x43),
  tuneMix5(0x44),
  tuneMix6(0x45),
  tuneMix7(0x46),
  tuneMix8(0x47),
  tuneMix9(0x48),
  tuneMix10(0x49);

  const ChanAttribListChangeType(this.value);
  final int value;

  static ChanAttribListChangeType getByValue(int i) {
    return ChanAttribListChangeType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum ChanSelectionType {
  tuneUsingSID(0x00),
  tuneUsingChannelNumber(0x01),
  tuneToNextHigherChannelNumberInCategory(0x02),
  tuneToNextLowerChannelNumberInCategory(0x03),
  scanChannelsInCategory(0x04),
  scanChannelsDefinedByChannelScanInclude(0x05),
  scanSmartFavoriteContent(0x06),
  scanSmartFavoriteMusicOnlyContent(0x07),
  skipBackToPreviousScanItem(0x08),
  skipForwardToNextScanItem(0x09),
  stopScanAndContinuePlaybackOfCurrentTrack(0x0A),
  abortScanAndResumePlaybackOfItemActiveAtScanInitiation(0x0B),
  skipOneScanItemInOppositeDirection(0x0C),
  setContentScanCriteriaForReporting(0x0D),
  setMusicOnlyContentScanCriteria(0x0E),
  playBulletin(0x0F),
  abortBulletinAndResumePlaybackOfPreviousContent(0x10),
  playFlashEvent(0x11),
  remainOnFlashEventChannel(0x12),
  abortFlashEventAndResumePlaybackOfPreviousContent(0x13);

  const ChanSelectionType(this.value);
  final int value;

  static ChanSelectionType getByValue(int i) {
    return ChanSelectionType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum PlayPoint {
  live(0),
  restart(1),
  auto(2);

  const PlayPoint(this.value);
  final int value;

  static PlayPoint getByValue(int i) {
    return PlayPoint.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum AudioRoutingType {
  noRouting(0),
  routeToAudio(1),
  routeToRecording(2),
  routeToAudioAndRecording(3);

  const AudioRoutingType(this.value);
  final int value;

  static AudioRoutingType getByValue(int i) {
    return AudioRoutingType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum MonitorChangeType {
  dontMonitor(0),
  monitor(1),
  dontMonitorAll(2);

  const MonitorChangeType(this.value);
  final int value;

  static MonitorChangeType getByValue(int i) {
    return MonitorChangeType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum FeatureMonitorType {
  time(0),
  channelInfo(1),
  categoryInfo(2),
  metadata(3),
  storedMetadata(4);

  const FeatureMonitorType(this.value);
  final int value;

  static FeatureMonitorType getByValue(int i) {
    return FeatureMonitorType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum StatusMonitorType {
  signalAndAntennaStatus(0x00),
  antennaAiming(0x03),
  audioDecoderBitrate(0x0B),
  signalQuality(0x0C),
  overlaySignalQuality(0x0D),
  moduleVersion(0x0E),
  gpsData(0x10),
  linkInformation(0x11),
  scanAvailableItems(0x12),
  audioPresence(0x13),
  debugDecoder(0x34),
  debugOffset(0x35),
  debugPipe(0x36),
  debugDataLayer(0x37),
  debugQueue(0x39),
  debugMfc(0x3a),
  debugAudioDecoder(0x3b),
  debugUpc(0x3c),
  debugQuality(0x3d);

  const StatusMonitorType(this.value);
  final int value;

  static StatusMonitorType getByValue(int i) {
    return StatusMonitorType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum MetadataMonitorType {
  extendedTrackMetadataForActiveAndBrowsedChannels(0),
  extendedTrackMetadataForAllChannels(1),
  extendedChannelMetadataForActiveAndBrowsedChannels(2),
  extendedChannelMetadataForAllChannels(3),
  extendedGlobalMetadata(4),
  lookAheadTrackMetadataForAllChannels(5);

  const MetadataMonitorType(this.value);
  final int value;

  static MetadataMonitorType getByValue(int i) {
    return MetadataMonitorType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum PlaybackControlType {
  reserved(0x00),
  live(0x01),
  play(0x02),
  pause(0x03),
  next(0x04),
  previous(0x05),
  jumpToStart(0x06),
  jumpToPlaybackID(0x07),
  jumpToTimeOffset(0x08),
  nextResume(0x09),
  previousResume(0x0A),
  jumpToStartResume(0x0B),
  jumpToPlaybackIDResume(0x0C),
  jumpToTimeOffsetResume(0x0D),
  jumpToMref(0x0E),
  jumpToMrefResume(0x0F);

  const PlaybackControlType(this.value);
  final int value;

  static PlaybackControlType getByValue(int i) {
    return PlaybackControlType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum PackageOptionType {
  query(0),
  select(1),
  validate(2),
  report(3);

  const PackageOptionType(this.value);
  final int value;

  static PackageOptionType getByValue(int i) {
    return PackageOptionType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum SeekControlType {
  disable(0),
  enableSeekEnd(1),
  enableSeekImmediate(2),
  enableSeekEndAndImmediate(3);

  const SeekControlType(this.value);
  final int value;

  static SeekControlType getByValue(int i) {
    return SeekControlType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum SeekMonitorType {
  songMonitor1(0),
  songMonitor2(1),
  artistMonitor1(2),
  artistMonitor2(3),
  seekMonitor4(4),
  seekMonitor5(5),
  seekMonitor6(6),
  seekMonitor7(7);

  const SeekMonitorType(this.value);
  final int value;

  static SeekMonitorType getByValue(int i) {
    return SeekMonitorType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum TimeZoneType {
  nt(0),
  at(1),
  et(2),
  ct(3),
  mt(4),
  pt(5),
  akt(6),
  hat(7),
  utc(8);

  const TimeZoneType(this.value);
  final int value;

  static TimeZoneType getByValue(int i) {
    return TimeZoneType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum DSTType {
  disable(0),
  auto(1);

  const DSTType(this.value);
  final int value;

  static DSTType getByValue(int i) {
    return DSTType.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum TrackMetadataIdentifier {
  songId(0x03),
  artistId(0x04),
  songName(0x05),
  artistName(0x06),
  currentInfo(0x08),
  sportBroadcastId(0x0A),
  gameTeamId(0x0B),
  leagueBroadcastId(0x0C),
  trafficCityId(0x0F),
  itunesSongId(0x0010);

  const TrackMetadataIdentifier(this.value);
  final int value;

  static TrackMetadataIdentifier getByValue(int i) {
    return TrackMetadataIdentifier.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum ChannelMetadataIdentifier {
  channelShortDescription(0x40),
  channelLongDescription(0x41),
  similarChannelList(0x42),
  channelListOrder(0x44);

  const ChannelMetadataIdentifier(this.value);
  final int value;

  static ChannelMetadataIdentifier getByValue(int i) {
    return ChannelMetadataIdentifier.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

enum GlobalMetadataIdentifier {
  channelMetadataTableVersion(0x102),
  channelMetadataRecordCount(0x202),
  itunesSxmUrl(0x82),
  trafficWeatherCityTableVersion(0x104),
  trafficWeatherCityRecordCount(0x204),
  trafficWeatherCityId(0x8D),
  trafficWeatherCityAbbreviation(0x8E),
  trafficWeatherCityName(0x8F),
  sportsTeamTableVersion(0x105),
  sportsTeamRecordCount(0x205),
  sportsTeamId(0x97),
  sportsTeamAbbreviation(0x98),
  sportsTeamName(0x99),
  sportsTeamNickname(0x9A),
  sportsTeamIdList(0x9B),
  sportsTeamTierList(0x9C),
  sportsLeagueTableVersion(0x106),
  sportsLeagueRecordCount(0x206),
  sportsLeagueId(0xA1),
  sportsLeagueShortName(0xA2),
  sportsLeagueLongName(0xA3),
  sportsLeagueType(0xA4);

  const GlobalMetadataIdentifier(this.value);
  final int value;

  static GlobalMetadataIdentifier getByValue(int i) {
    return GlobalMetadataIdentifier.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid value: $i'));
  }
}

class ChannelAttributes {
  static const int freeToAir = 1 << 0;
  static const int locked = 1 << 1;
  static const int mature = 1 << 2;
  static const int skipped = 1 << 3;
  static const int unrestricted = 1 << 4;
  static const int unsubscribed = 1 << 5;
  static int all() => freeToAir | locked | mature | skipped | unrestricted;

  static const Map<int, String> _names = <int, String>{
    freeToAir: 'freeToAir',
    locked: 'locked',
    mature: 'mature',
    skipped: 'skipped',
    unrestricted: 'unrestricted',
    unsubscribed: 'unsubscribed',
  };

  static String? nameOf(int value) => _names[value];

  static List<String> namesFromMask(int mask) {
    final List<String> result = <String>[];
    _names.forEach((int bit, String name) {
      if ((mask & bit) != 0) {
        result.add(name);
      }
    });
    return result;
  }

  static bool contains(int mask, int attributeBit) =>
      (mask & attributeBit) != 0;
}
