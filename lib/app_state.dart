// AppState, the main state of the application
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:orbit/metadata/channel_data.dart';
import 'package:orbit/data/data_handlers.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/metadata/signal_quality.dart';
import 'package:orbit/storage/storage_data.dart';
import 'package:orbit/ui/preset.dart';
import 'package:logger/logger.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/sxi_indication_types.dart';
import 'package:orbit/debug_tools_stub.dart'
    if (dart.library.io) 'package:orbit/debug_tools.dart';

class AppState extends ChangeNotifier {
  final List<Preset> presets = List.generate(18, (_) => Preset());
  final List<double> eqSliderValues = List.generate(12, (_) => 0.0);
  bool enableAudio = false;
  bool tuneStart = false;
  bool sliderSnapping = true;
  bool debugMode = false;
  // Android-only: preferred audio output route
  String androidAudioOutputRoute = 'Speaker';
  bool isScanActive = false;
  bool isTuneMixActive = false;
  ThemeMode themeMode = ThemeMode.dark;
  double uiScale = 1.0;
  Level logLevel = kDebugMode ? Level.debug : Level.info;
  // Audio sample rate in Hz (configurable)
  int audioSampleRate = 48000;
  int secondaryBaudRate = 460800;
  int _lastSid = 0;
  bool linkTraceEnabled = false;
  final Set<DataServiceIdentifier> monitoredDataServices =
      <DataServiceIdentifier>{};

  final StorageData storageData = StorageData();

  final PropertyValueNotifier<PlaybackInfo> playbackInfoNotifier =
      PropertyValueNotifier(PlaybackInfo.empty());
  final ValueNotifier<AppPlaybackState> playbackStateNotifier =
      ValueNotifier(AppPlaybackState.stopped);

  PlaybackInfo get nowPlaying => playbackInfoNotifier.value;

  final Map<int, List<int>> _categories = {};
  final Map<int, ChannelData> sidMap = {};
  bool _updatingCategories = false;
  bool _updatingChannels = false;
  int _currentCategory = 0;
  int _currentChannel = 0;
  int _currentSid = 0;
  int _signalStatus = 0;
  bool _antennaConnected = false;
  bool _audioExpected = false;
  int _audioDecoderBitrate = 0;
  SignalQuality? _baseSignalQuality;
  OverlaySignalQuality? _overlaySignalQualityData;

  int _subscriptionStatus = -1;
  String _subscriptionReasonText = '';
  String _subscriptionPhoneNumber = '';

  String _moduleType = '';
  String _moduleHWRev = '';
  String _moduleSWRev = '';
  String _sxiRev = '';
  String _basebandRev = '';
  String _hardwareDecoderRev = '';
  String _rfRev = '';
  String _splRev = '';
  int _bufferDuration = 0;
  int _maxSmartFavorites = 0;
  int _maxTuneMix = 0;
  int _maxSportsFlash = 0;
  int _maxTWNow = 0;

  DateTime? _deviceTime;

  int _playbackId = 0;
  int _playbackState = 0;
  int _playbackPosition = 0;
  int _playbackDuration = 0;
  int _playbackTimeFromStart = 0;
  int _playbackRemainingTracks = 0;
  int _playbackTimeRemaining = 0;
  int _playbackTimeBefore = 0;

  // Getters
  int get lastSid => _lastSid;
  bool get isAntennaConnected => _antennaConnected;
  bool get updatingCategories => _updatingCategories;
  bool get updatingChannels => _updatingChannels;
  int get playbackTimeRemaining => _playbackTimeRemaining;
  int get playbackTimeBefore => _playbackTimeBefore;
  int get signalQuality => _signalStatus;
  int get currentChannel => _currentChannel;
  int get currentSid => _currentSid;
  int get subscriptionStatus => _subscriptionStatus;
  String get subscriptionReasonText => _subscriptionReasonText;
  String get subscriptionPhoneNumber => _subscriptionPhoneNumber;
  SignalQuality? get baseSignalQuality => _baseSignalQuality;
  OverlaySignalQuality? get overlaySignalQualityData =>
      _overlaySignalQualityData;
  bool get audioPresence => _audioExpected;
  int get audioDecoderBitrate => _audioDecoderBitrate;

  // System info getters
  String get moduleType => _moduleType;
  String get moduleHWRev => _moduleHWRev;
  String get moduleSWRev => _moduleSWRev;
  String get sxiRev => _sxiRev;
  String get basebandRev => _basebandRev;
  String get hardwareDecoderRev => _hardwareDecoderRev;
  String get rfRev => _rfRev;
  String get splRev => _splRev;
  int get bufferDuration => _bufferDuration;
  int get maxSmartFavorites => _maxSmartFavorites;
  int get maxTuneMix => _maxTuneMix;
  int get maxSportsFlash => _maxSportsFlash;
  int get maxTWNow => _maxTWNow;
  DateTime? get deviceTime => _deviceTime;

  Map<int, String> get categories => SplayTreeMap<int, String>.from(_categories
      .map((catId, catName) => MapEntry(catId, String.fromCharCodes(catName))));

  Map<int, PlaybackInfo> channelPlaybackMetadata = {};
  final Map<int, Map<int, List<int>>> imageMap = {};

  String get currentCategoryString => _categories[_currentCategory] != null
      ? String.fromCharCodes(_categories[_currentCategory]!)
      : 'None';

  int get currentCategory => _currentCategory;

  AppPlaybackState get playbackState {
    return _playbackState < AppPlaybackState.values.length
        ? AppPlaybackState.values[_playbackState]
        : AppPlaybackState.live;
  }

  String get playbackInfo => '''
      ID: $_playbackId
      Position: $_playbackPosition
      Duration: $_playbackDuration
      TimeFromStart: $_playbackTimeFromStart
      TimeRemaining: $_playbackTimeRemaining
      TimeBefore: $_playbackTimeBefore
      TracksRemaining: $_playbackRemainingTracks
  ''';

  // Load user-facing settings and cached data from storage
  Future<void> initialize() async {
    await storageData.init();
    // Load persisted log level and apply
    final dynamic savedLogLevelValue = await storageData.load(
      SaveDataType.logLevel,
      defaultValue: kDebugMode ? Level.debug.value : Level.info.value,
    );
    final parsedLevel = Level.values.firstWhere(
      (level) => level.value == savedLogLevelValue,
      orElse: () => kDebugMode ? Level.debug : Level.info,
    );
    logLevel = parsedLevel;
    try {
      AppLogger.instance.setLevel(parsedLevel);
    } catch (_) {}

    // Load EQ (defaults: Vol=-15, Gain=-5)
    // The device boots at 0 Vol and 0 Gain which is way too loud
    final Int8List? loadedEq = await storageData.load(
      SaveDataType.eq,
      defaultValue: null,
    );
    final Int8List eqValues = loadedEq ??
        Int8List.fromList(<int>[-15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -5]);
    if (loadedEq == null) {
      await storageData.save(SaveDataType.eq, eqValues);
    }
    for (int i = 0; i < eqValues.length.clamp(0, eqSliderValues.length); i++) {
      eqSliderValues[i] = eqValues[i].toDouble();
    }

    // Last tuned SID
    _lastSid = await storageData.load(
      SaveDataType.lastSid,
      defaultValue: 0,
    );

    // Stored presets
    final List<Preset> loadedPresets = await storageData.load(
      SaveDataType.presets,
      defaultValue: List<Preset>.empty(),
    );
    for (int i = 0; i < loadedPresets.length.clamp(0, presets.length); i++) {
      presets[i] = loadedPresets[i];
    }

    // Preferences and flags
    enableAudio = await storageData.load(
      SaveDataType.enableAudio,
      defaultValue: false,
    );
    tuneStart = await storageData.load(
      SaveDataType.tuneStart,
      defaultValue: false,
    );
    sliderSnapping = await storageData.load(
      SaveDataType.sliderSnapping,
      defaultValue: true,
    );
    debugMode = await storageData.load(
      SaveDataType.debugMode,
      defaultValue: kDebugMode,
    );

    // Load preferred secondary baud rate
    secondaryBaudRate = await storageData.load(
      SaveDataType.secondaryBaudRate,
      defaultValue: 460800,
    );

    linkTraceEnabled = await storageData.load(
      SaveDataType.linkTraceEnabled,
      defaultValue: false,
    );

    // Enable link tracing if enabled in settings
    try {
      await FrameTracer.instance.setEnabled(linkTraceEnabled);
    } catch (_) {}

    final List<dynamic> monitoredList = await storageData.load(
      SaveDataType.monitoredDataServices,
      defaultValue: <int>[],
    );

    // Load monitored data services
    monitoredDataServices
      ..clear()
      ..addAll(monitoredList
          .map((e) => e is int ? e : int.tryParse(e.toString()) ?? -1)
          .where((v) => v >= 0)
          .map((v) {
        try {
          return DataServiceIdentifier.getByValue(v);
        } catch (_) {
          return DataServiceIdentifier.none;
        }
      }).where((e) => e != DataServiceIdentifier.none));

    // Load theme and UI scale
    final int themeModeIndex = await storageData.load(
      SaveDataType.themeMode,
      defaultValue: ThemeMode.dark.index,
    );
    themeMode =
        ThemeMode.values[themeModeIndex.clamp(0, ThemeMode.values.length - 1)];

    uiScale = await storageData.load(
      SaveDataType.uiScale,
      defaultValue: 1.0,
    );

    // Load Android audio route preference
    androidAudioOutputRoute = await storageData.load(
      SaveDataType.audioOutputRoute,
      defaultValue: 'Speaker',
    );

    // Load audio sample rate preference (default 48000)
    audioSampleRate = await storageData.load(
      SaveDataType.audioSampleRate,
      defaultValue: 48000,
    );

    notifyListeners();
  }

  void updateLastSid(int sid) {
    _lastSid = sid;
    storageData.save(SaveDataType.lastSid, sid);
    notifyListeners();
  }

  void updateChannelGraphicsImage(ChannelLogoInfo channelGraphicsData) {
    if (imageMap.containsKey(channelGraphicsData.chanLogoId)) {
      if (imageMap[channelGraphicsData.chanLogoId]!
          .containsKey(channelGraphicsData.seqNum)) {
        return;
      }
    }

    storageData.saveImage(channelGraphicsData);
  }

  void updateServiceGraphicsReferenceData(
      List<ServiceGraphicsReference> serviceGraphicsReferences) {
    storageData.saveGraphicsList(serviceGraphicsReferences);
  }

  // EQ and Audio updates
  void updateEqValue(int index, double value) {
    eqSliderValues[index] = value;
    notifyListeners();
  }

  void updateEnableAudio(bool enabled) {
    enableAudio = enabled;
    storageData.save(SaveDataType.enableAudio, enableAudio);
    notifyListeners();
  }

  void updateTuneStart(bool enabled) {
    tuneStart = enabled;
    storageData.save(SaveDataType.tuneStart, tuneStart);
    notifyListeners();
  }

  void updateSliderSnapping(bool enabled) {
    sliderSnapping = enabled;
    storageData.save(SaveDataType.sliderSnapping, sliderSnapping);
    notifyListeners();
  }

  void updateDebugMode(bool enabled) {
    debugMode = enabled;
    storageData.save(SaveDataType.debugMode, debugMode);
    notifyListeners();
  }

  // Android-only: update and persist preferred audio output route
  void updateAndroidAudioOutputRoute(String route) {
    androidAudioOutputRoute = route;
    storageData.save(SaveDataType.audioOutputRoute, androidAudioOutputRoute);
    notifyListeners();
  }

  void updateSecondaryBaudRate(int baudRate) {
    secondaryBaudRate = baudRate;
    storageData.save(SaveDataType.secondaryBaudRate, secondaryBaudRate);
    notifyListeners();
  }

  void updateAudioSampleRate(int sampleRateHz) {
    audioSampleRate = sampleRateHz;
    storageData.save(SaveDataType.audioSampleRate, audioSampleRate);
    notifyListeners();
  }

  void updateThemeMode(ThemeMode mode) {
    themeMode = mode;
    storageData.save(SaveDataType.themeMode, mode.index);
    notifyListeners();
  }

  void updateUiScale(double scale) {
    uiScale = scale.clamp(0.6, 2.0);
    storageData.save(SaveDataType.uiScale, uiScale);
    notifyListeners();
  }

  void updateLogLevel(Level level) {
    logLevel = level;
    storageData.save(SaveDataType.logLevel, level.value);
    try {
      AppLogger.instance.setLevel(level);
    } catch (_) {}
    notifyListeners();
  }

  void updateLinkTraceEnabled(bool enabled) {
    linkTraceEnabled = enabled;
    storageData.save(SaveDataType.linkTraceEnabled, enabled);
    try {
      FrameTracer.instance.setEnabled(enabled);
    } catch (_) {}
    notifyListeners();
  }

  void updateMonitoredDataServices(Set<DataServiceIdentifier> services) {
    monitoredDataServices
      ..clear()
      ..addAll(services);
    final List<int> values = services.map((e) => e.value).toList();
    storageData.save(SaveDataType.monitoredDataServices, values);
    notifyListeners();
  }

  void resetEqValues() {
    eqSliderValues.fillRange(0, eqSliderValues.length, 0.0);
    notifyListeners();
  }

  void updateAudioExpectedStatus(bool audioExpected) {
    _audioExpected = audioExpected;
    notifyListeners();
  }

  void updateAudioDecoderBitrate(int bitrate) {
    _audioDecoderBitrate = bitrate;
    notifyListeners();
  }

  void updateBaseSignalQuality(SignalQuality signalQuality) {
    _baseSignalQuality = signalQuality;
    notifyListeners();
  }

  void updateOverlaySignalQualityData(
      OverlaySignalQuality overlaySignalQuality) {
    _overlaySignalQualityData = overlaySignalQuality;
    notifyListeners();
  }

  void updateSignalStatus(int signal, bool antennaConnected) {
    _signalStatus = signal;
    _antennaConnected = antennaConnected;
    notifyListeners();
  }

  void updateSubscriptionStatus(
      int status, String reasonText, String phoneNumber) {
    _subscriptionStatus = status;
    _subscriptionReasonText = reasonText;
    _subscriptionPhoneNumber = phoneNumber;
    notifyListeners();
  }

  void updateModuleConfiguration(
    int moduleTypeIDA,
    int moduleTypeIDB,
    int moduleTypeIDC,
    int moduleHWRevA,
    int moduleHWRevB,
    int moduleHWRevC,
    int modSWRevMajor,
    int modSWRevMinor,
    int modSWRevInc,
    int sxiRevMajor,
    int sxiRevMinor,
    int sxiRevInc,
    int bbRevMajor,
    int bbRevMinor,
    int bbRevInc,
    int hDecRevMajor,
    int hDecRevMinor,
    int hDecRevInc,
    int rfRevMajor,
    int rfRevMinor,
    int rfRevInc,
    int splRevMajor,
    int splRevMinor,
    int splRevInc,
    int durationOfBuffer,
    int maxSmartFavorites,
    int maxTuneMix,
    int maxSportsFlash,
    int maxTWNow,
  ) {
    _moduleType = '$moduleTypeIDA.$moduleTypeIDB.$moduleTypeIDC';
    _moduleHWRev = '$moduleHWRevA.$moduleHWRevB.$moduleHWRevC';
    _moduleSWRev = '$modSWRevMajor.$modSWRevMinor.$modSWRevInc';
    _sxiRev = '$sxiRevMajor.$sxiRevMinor.$sxiRevInc';
    _basebandRev = '$bbRevMajor.$bbRevMinor.$bbRevInc';
    _hardwareDecoderRev = '$hDecRevMajor.$hDecRevMinor.$hDecRevInc';
    _rfRev = '$rfRevMajor.$rfRevMinor.$rfRevInc';
    _splRev = '$splRevMajor.$splRevMinor.$splRevInc';
    _bufferDuration = durationOfBuffer;
    _maxSmartFavorites = maxSmartFavorites;
    _maxTuneMix = maxTuneMix;
    _maxSportsFlash = maxSportsFlash;
    _maxTWNow = maxTWNow;
    notifyListeners();
  }

  void updateDeviceTime(int minute, int hour, int day, int month, int year) {
    try {
      _deviceTime = DateTime(year, month, day, hour, minute);
    } catch (e) {
      _deviceTime = null;
    }
    notifyListeners();
  }

  void addChannel(int sid, int channel, String channelName, int catId) {
    if (sid == 0) {
      _updatingChannels = false;
    } else {
      _updatingChannels = true;
    }

    sidMap[sid] = ChannelData(sid, channel, catId, channelName);
    _updatePresetsForSid(sid, artist: '', song: '');
    notifyListeners();
  }

  void addCategory(int catId, List<int> categoryName) {
    if (catId == 255) {
      _updatingCategories = false;
    } else {
      _updatingCategories = true;
    }

    _categories[catId] = categoryName;
  }

  void updateChannelData(int sid, String artist, String song, int programId) {
    final channelData = sidMap[sid];
    if (channelData != null) {
      channelData
        ..currentArtist = artist
        ..currentSong = song
        ..currentPid = programId;
      _updatePresetsForSid(sid, artist: artist, song: song);
      notifyListeners();
    }
  }

  void updateChannelDescriptions(
      int sid, String shortDescription, String longDescription) {
    final channelData = sidMap[sid];
    if (channelData != null) {
      channelData
        ..channelShortDescription = shortDescription
        ..channelLongDescription = longDescription;
      notifyListeners();
    }
  }

  void updateSimilarChannels(int sid, List<int> similarChannelIds) {
    final channelData = sidMap[sid];
    if (channelData != null) {
      channelData.similarSids = List<int>.from(similarChannelIds);
      notifyListeners();
    }
  }

  void updateTrackIdsForSid(int sid, {int? songId, int? artistId}) {
    final channelData = sidMap[sid];
    if (channelData != null) {
      if (songId != null) channelData.currentSongId = songId;
      if (artistId != null) channelData.currentArtistId = artistId;
      notifyListeners();
    }
  }

  void _updatePresetsForSid(int sid,
      {required String artist, required String song}) {
    final channelData = sidMap[sid];
    if (channelData == null) return;
    for (var preset in presets.where((p) => p.sid == sid)) {
      preset
        ..channelNumber = channelData.channelNumber
        ..channelName = channelData.channelName
        ..artist = artist
        ..song = song;
    }
  }

  void updatePlaybackState(
    int playbackState,
    int playbackId,
    int playbackPosition,
    int playbackDuration,
    int playbackTimeFromStart,
    int playbackRemainingTracks,
    int playbackTimeRemaining,
    int playbackTimeBefore,
  ) {
    _playbackId = playbackId;
    _playbackPosition = playbackPosition;
    _playbackDuration = playbackDuration;
    _playbackTimeFromStart = playbackTimeFromStart;
    _playbackRemainingTracks = playbackRemainingTracks;
    _playbackTimeRemaining = playbackTimeRemaining;
    _playbackTimeBefore = playbackTimeBefore;
    _playbackState = playbackState;

    nowPlaying.state = AppPlaybackState.values[playbackState];
    playbackStateNotifier.value = AppPlaybackState.values[playbackState];
    if (!isTuneMixActive) {
      playbackInfoNotifier.notifyListeners();
    }
    notifyListeners();
  }

  void updateNowPlayingCategory(int catId) {
    _currentCategory = catId;
    nowPlaying.channelCategory = currentCategoryString;
  }

  void updateNowPlayingChannelName(List<int> newStation) {
    nowPlaying.channelName = String.fromCharCodes(newStation);
  }

  void updateNowPlayingSong(List<int> newSong) {
    nowPlaying.songTitle = String.fromCharCodes(newSong);
  }

  void updateNowPlayingArtist(List<int> newArtist) {
    nowPlaying.artistTitle = String.fromCharCodes(newArtist);
  }

  void updateNowPlayingChannel(int channel, int sid) {
    logger.t('Updating now playing channel: $channel, sid: $sid');
    if (_currentChannel != channel) {
      clearChannelPlaybackMetadata();
    }
    _currentChannel = channel;
    _currentSid = sid;
    nowPlaying
      ..channelNumber = channel
      ..sid = sid;
  }

  void updateNowPlayingProgram(Uint8List programId) {
    nowPlaying.programId = programId;
  }

  void updateNowPlayingWithNewData(
      List<int> newStation,
      List<int> newSong,
      List<int> newArtist,
      int catId,
      int channel,
      int sid,
      Uint8List programId,
      List<int> img) {
    logger.i(
        'Updating now playing with new data, SID: $sid, Channel: $channel, Program: $programId');

    if (newStation.isNotEmpty) {
      updateNowPlayingChannelName(newStation);
    }
    updateNowPlayingSong(newSong);
    updateNowPlayingArtist(newArtist);
    if (catId != -1) {
      updateNowPlayingCategory(catId);
    }
    updateNowPlayingChannel(channel, sid);
    updateNowPlayingProgram(programId);
    updateNowPlayingChannelImage();
    updateNowPlayingImage(img);
    updateNowPlaying();
    playbackStateNotifier.notifyListeners();
  }

  void updateNowPlaying() {
    notifyListeners();
    playbackInfoNotifier.notifyListeners();
  }

  void updateNowPlayingImage(List<int> img) {
    nowPlaying.image = Uint8List.fromList(img);
  }

  void updateNowPlayingChannelImage() {
    logger.t(
        'Updating now playing channel image for channel ${nowPlaying.channelNumber}');
    logger.t('Now playing sid: ${nowPlaying.sid}');
    nowPlaying.channelImage =
        Uint8List.fromList(storageData.getImageForSid(nowPlaying.sid));
  }

  void clearChannelPlaybackMetadata() {
    channelPlaybackMetadata.clear();
  }

  int? getSidFromChannelId(int channelId) {
    for (final entry in sidMap.entries) {
      if (entry.value.channelNumber == channelId) {
        return entry.key;
      }
    }
    return null;
  }

  int? getChannelIdFromSid(int sid) {
    for (final entry in sidMap.entries) {
      if (entry.key == sid) {
        return entry.value.channelNumber;
      }
    }
    return null;
  }

  void addChannelPlaybackMetadata(int playbackId, int channelId,
      List<int> programId, int duration, String songName, String artistName) {
    final programIdInt = bytesToInt32(programId);
    final sid = getSidFromChannelId(channelId) ?? -1;

    // Get album art for this program if available
    final albumArt = imageMap[sid]?[programIdInt] ?? [];

    channelPlaybackMetadata[programIdInt] = PlaybackInfo.empty()
      ..songTitle = songName
      ..artistTitle = artistName
      ..channelNumber = channelId
      ..duration = duration
      ..sid = sid
      ..programId = Uint8List.fromList(programId)
      ..image = Uint8List.fromList(albumArt);

    logger.t('Adding channel playback metadata for channel $channelId');
  }

  void setImageForExistingProgram(int sid, int programId, List<int> image) {
    if (channelPlaybackMetadata.containsKey(programId)) {
      if (channelPlaybackMetadata[programId]!.sid == sid) {
        channelPlaybackMetadata[programId]!.image = Uint8List.fromList(image);
      }
    }
  }
}

class PlaybackInfo {
  String channelName;
  String channelCategory;
  String songTitle;
  String artistTitle;
  Uint8List channelImage;
  int duration;
  int channelNumber;
  int sid;
  AppPlaybackState state;
  Uint8List programId;
  Uint8List image;

  PlaybackInfo(
    this.channelName,
    this.channelCategory,
    this.songTitle,
    this.artistTitle,
    this.channelImage,
    this.channelNumber,
    this.duration,
    this.sid,
    this.state,
    this.programId,
    this.image,
  );

  PlaybackInfo.empty()
      : channelName = '',
        channelCategory = '',
        songTitle = '',
        artistTitle = '',
        channelImage = Uint8List(0),
        channelNumber = 0,
        duration = 0,
        sid = 0,
        state = AppPlaybackState.stopped,
        programId = Uint8List(0),
        image = Uint8List(0);
}

enum AppPlaybackState { live, paused, recordedContent, stopped }

class PropertyValueNotifier<T> extends ValueNotifier<T> {
  PropertyValueNotifier(super.value);
}
