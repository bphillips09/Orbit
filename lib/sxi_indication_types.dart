// Data service identifiers for the SXi protocol
// Mostly self-explanatory
enum DataServiceIdentifier {
  none(0),
  electronicProgramGuide(0x12c),
  channelGraphicsUpdates(0x137),
  phoneticsUpdate(0x14a),
  xmNavTraffic(0x190),
  xmWxWeatherAppId10(0x19a),
  xmWxWeatherAppId230(0xe6),
  xmWxWeatherAppId231(0xe7),
  xmWxWeatherAppId232(0xe8),
  xmWxWeatherAppId234(0xea),
  xmWxWeatherAppId235(0xeb),
  xmWxWeatherAppId236(0xec),
  xmWxWeatherAppId237(0xed),
  xmWxWeatherAppId238(0xee),
  xmNavWeather(0x1ae),
  sxmWeatherTabular(0x1b8),
  sxmWeatherAlerts(0x1b9),
  sxmWeatherGraphical(0x1ba),
  sxmMarineInland(0x1bb),
  sxmMarineMariner(0x1bc),
  sxmMarineVoyager(0x1bd),
  sxmAviationBasic(0x1be),
  sxmAviationStandard(0x1bf),
  sxmAviationPremium(0x1c0),
  traffic(0x1e0),
  apogeeTraffic0(0x1ea),
  apogeeTraffic1(0x1eb),
  apogeeTrafficCameras(0x1ec),
  stockTickers(0x1f4),
  airTravel(0x208),
  sports(0x212),
  fuelPrices(0x258),
  movieTimes(0x262),
  safetyCameras(0x26c),
  parking(0x280),
  albumArt(0x13b),
  showcase(0x32a),
  v2v(0x2c1), // Vehicle to vehicle?
  v2vCrl(0x2bc), // Vehicle to vehicle control?
  ev(0x276),
  ivsm(0x27b); // In vehicle subscription messaging?

  const DataServiceIdentifier(this.value);
  final int value;

  static final Map<int, DataServiceIdentifier> dmiToDsiMap = {};

  static DataServiceIdentifier getByDMI(int dmi) {
    return dmiToDsiMap[dmi] ?? DataServiceIdentifier.none;
  }

  static void addDMI(int dsi, List<int> dmiList) {
    for (var dmi in dmiList) {
      dmiToDsiMap[dmi] = DataServiceIdentifier.getByValue(dsi);
    }
  }

  static DataServiceIdentifier getByValue(int i) {
    return DataServiceIdentifier.values.firstWhere((x) => x.value == i,
        orElse: () => throw ArgumentError('Invalid DataType value: $i'));
  }
}

// Device error codes
enum SXiError {
  ok(0),
  busy(1),
  error(2),
  fault(3),
  invalid(4),
  noEntry(5),
  noMemory(6),
  pipe(7),
  state(8),
  thread(9),
  timeout(10),
  corrupt(11),
  unsupported(12),
  resource(13),
  updating(14),
  reset(15),
  noDb(16),
  badDb(17),
  size(200),
  badPacket(201),
  arraySize(202),
  bufferSize(203),
  badString(204),
  badLabel(205),
  noLocation(514),
  badLocation(515),
  noState(516),
  badState(517),
  noSubNotification(518),
  badCrc(600),
  pathfileError(601),
  linkEstablished(700),
  linkPending(701),
  linkLoss(702),
  moduleTempCritical(703),
  moduleReconfiguration(704),
  noMref(800),
  cacheDuplicate(801),
  other(65520),
  param(65521),
  ipc(65522),
  internal(65523),
  notExist(65524),
  alreadyExist(65525),
  limitReached(65526),
  rejected(65527);

  const SXiError(this.value);
  final int value;

  static SXiError getByValue(int i) {
    return SXiError.values
        .firstWhere((x) => x.value == i, orElse: () => SXiError.other);
  }
}

// Device indication codes
enum IndicationCode {
  nominal(0),
  channelOrCategoryAddedOrUpdated(1),
  channelOrCategoryDeleted(2),
  requestedOperationFailed(3),
  noChannelMeetsRequest(4),
  checkAntenna(5),
  noSignal(6),
  subscriptionUpdate(7),
  channelUnavailable(8),
  channelUnsubscribed(9),
  channelLocked(10),
  channelMature(11),
  factoryActivationAlreadySelected(12),
  factoryActivationMultiPackageArrayInvalid(13),
  factoryActivationOtaInvalid(14),
  factoryActivationIndexInvalid(15),
  factoryActivationSelectionRequired(16),
  factoryActivationErrorCapIoError(24),
  factoryActivationErrorCapNvmInvalid(26),
  factoryActivationErrorUnbound(27),
  factoryActivationErrorOtpInvalid(28),
  factoryActivationErrorCrypto(29),
  resourceLimit(30),
  noTracks(31),
  scanNominal(32),
  channelAudioUnavailable(33),
  recordFail(34),
  scanAborted(35),
  tuneMixNominal(36),
  bulletinNominal(37),
  bulletinUnavailable(38),
  flashEventNominal(39),
  flashEventUnavailable(40),
  seekEnd(41),
  unknown(-1);

  const IndicationCode(this.value);
  final int value;

  static IndicationCode getByValue(int i) {
    return IndicationCode.values
        .firstWhere((x) => x.value == i, orElse: () => unknown);
  }
}

// Service subscription status
enum SubscriptionStatus {
  none(0),
  partial(1),
  full(2),
  unknown(3);

  const SubscriptionStatus(this.value);
  final int value;

  static SubscriptionStatus getByValue(int i) {
    return SubscriptionStatus.values
        .firstWhere((x) => x.value == i, orElse: () => unknown);
  }
}
