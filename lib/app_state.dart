// AppState, the main state of the application
import 'dart:collection';
import 'dart:async';
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
import 'package:orbit/data/favorite.dart';
import 'package:orbit/data/favorites_on_air_entry.dart';
import 'package:orbit/data/favorite_on_air_event.dart';
import 'package:orbit/debug_tools_stub.dart'
    if (dart.library.io) 'package:orbit/debug_tools.dart';

class AppState extends ChangeNotifier {
  static const int favoritesPerMonitorCapacity = 60;
  // Maximum per type (spread across multiple monitors)
  static const int favoritesMaxPerTypeTotal = 120;
  final List<Favorite> favorites = <Favorite>[];
  final List<FavoriteOnAirEntry> _favoritesOnAirEntries =
      <FavoriteOnAirEntry>[];
  final Map<String, Timer> _favoritesOnAirTimers = <String, Timer>{};
  final List<Preset> presets = List.generate(18, (_) => Preset());
  final List<double> eqSliderValues = List.generate(12, (_) => 0.0);
  bool enableAudio = false;
  bool tuneStart = false;
  bool sliderSnapping = true;
  bool showOnAirFavoritesPrompt = true;
  bool welcomeSeen = false;
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
  final ValueNotifier<FavoriteOnAirEvent?> favoriteOnAirNotifier =
      ValueNotifier<FavoriteOnAirEvent?>(null);

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

  List<FavoriteOnAirEntry> get favoritesOnAirEntries =>
      List<FavoriteOnAirEntry>.unmodifiable(_favoritesOnAirEntries);

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

    // Stored favorites
    final List<Favorite> loadedFavorites = await storageData.load(
      SaveDataType.favorites,
      defaultValue: <Favorite>[],
    );
    favorites
      ..clear()
      ..addAll(loadedFavorites);

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
    showOnAirFavoritesPrompt = await storageData.load(
      SaveDataType.showOnAirFavoritesPrompt,
      defaultValue: true,
    );
    debugMode = await storageData.load(
      SaveDataType.debugMode,
      defaultValue: kDebugMode,
    );

    // First-time welcome flag
    welcomeSeen = await storageData.load(
      SaveDataType.welcomeSeen,
      defaultValue: false,
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

  void matchedSongSeekStarted(int songId, int sid, int channel) {
    try {
      Favorite matchedFavorite = favorites.firstWhere((f) => f.id == songId);
      logger.d(
          'Song Seek Match Started on channel: $channel, song: ${matchedFavorite.artistName} ($songId)');
      _addFavoriteOnAirEntry(
        sid: sid,
        channelNumber: channel,
        matchedId: songId,
        type: FavoriteType.song,
      );
      favoriteOnAirNotifier.value = FavoriteOnAirEvent(
        type: FavoriteType.song,
        matchedId: songId,
        sid: sid,
        channelNumber: channel,
        artistName: matchedFavorite.artistName,
        songName: matchedFavorite.songName,
      );
    } catch (e) {
      logger.d('No matched favorite found for song id: $songId');
    }
  }

  void matchedArtistSeekStarted(int artistId, int sid, int channel) {
    try {
      Favorite matchedFavorite = favorites.firstWhere((f) => f.id == artistId);
      logger.d(
          'Artist Seek Match Started on channel: $channel, artist: ${matchedFavorite.artistName} ($artistId)');
      _addFavoriteOnAirEntry(
        sid: sid,
        channelNumber: channel,
        matchedId: artistId,
        type: FavoriteType.artist,
      );
      favoriteOnAirNotifier.value = FavoriteOnAirEvent(
        type: FavoriteType.artist,
        matchedId: artistId,
        sid: sid,
        channelNumber: channel,
        artistName: matchedFavorite.artistName,
      );
    } catch (e) {
      logger.d('No matched favorite found for artist id: $artistId');
    }
  }

  void matchedSongSeekEnded(int songId, int sid, int channel) {
    try {
      Favorite matchedFavorite = favorites.firstWhere((f) => f.id == songId);
      logger.d(
          'Song Seek Match Ended on channel: $channel, song: ${matchedFavorite.artistName} ($songId)');
      _removeFavoriteOnAirEntry(
          sid: sid, matchedId: songId, type: FavoriteType.song);
    } catch (e) {
      logger.d('No matched favorite found for song id: $songId');
    }
  }

  void matchedArtistSeekEnded(int artistId, int sid, int channel) {
    try {
      Favorite matchedFavorite = favorites.firstWhere((f) => f.id == artistId);
      logger.d(
          'Artist Seek Match Ended on channel: $channel, artist: ${matchedFavorite.artistName} ($artistId)');
      _removeFavoriteOnAirEntry(
          sid: sid, matchedId: artistId, type: FavoriteType.artist);
    } catch (e) {
      logger.d('No matched favorite found for artist id: $artistId');
    }
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

  void updateShowOnAirFavoritesPrompt(bool enabled) {
    showOnAirFavoritesPrompt = enabled;
    storageData.save(SaveDataType.showOnAirFavoritesPrompt, enabled);
    notifyListeners();
  }

  void updateDebugMode(bool enabled) {
    debugMode = enabled;
    storageData.save(SaveDataType.debugMode, debugMode);
    notifyListeners();
  }

  void updateWelcomeSeen(bool seen) {
    welcomeSeen = seen;
    storageData.save(SaveDataType.welcomeSeen, welcomeSeen);
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

  void updateNowAiringTrackIdsForSid(int sid, {int? songId, int? artistId}) {
    logger.t(
        'Updating now airing track ids for sid: $sid, songId: $songId, artistId: $artistId');
    final channelData = sidMap[sid];
    if (channelData != null) {
      channelData.airingSongId = songId ?? 0;
      channelData.airingArtistId = artistId ?? 0;
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

  // Favorites helpers
  int countFavoritesByType(FavoriteType type) {
    return favorites.where((f) => f.type == type).length;
  }

  bool isAtCapacityForType(FavoriteType type) {
    return countFavoritesByType(type) >= favoritesMaxPerTypeTotal;
  }

  bool isNowPlayingSongFavorited() {
    final int songId = nowPlaying.songId;
    final int artistId = nowPlaying.artistId;
    if (songId == 0 || songId == 0xFFFFFFFF || songId == 0xFFFF) return false;
    if (artistId == 0 || artistId == 0xFFFFFFFF || artistId == 0xFFFF) {
      return false;
    }
    return favorites.any((f) => f.isSong && f.id == songId);
  }

  bool isNowPlayingArtistFavorited() {
    final int artistId = nowPlaying.artistId;
    if (artistId == 0 || artistId == 0xFFFFFFFF || artistId == 0xFFFF) {
      return false;
    }
    return favorites.any((f) => f.isArtist && f.id == artistId);
  }

  void addFavorite(Favorite favorite) {
    if (favorites.any((f) => f.type == favorite.type && f.id == favorite.id)) {
      return;
    }
    // Enforce per-monitor capacity
    if (isAtCapacityForType(favorite.type)) {
      return;
    }
    favorites.add(favorite);
    storageData.save(SaveDataType.favorites, favorites);
    // If this favorite is currently airing on any channel, add an entry now
    _syncOnAirAfterAddition(favorite);
    notifyListeners();
  }

  void removeFavorite(Favorite favorite) {
    favorites
        .removeWhere((f) => f.type == favorite.type && f.id == favorite.id);
    storageData.save(SaveDataType.favorites, favorites);
    // If this favorite was currently airing, remove its on-air entries
    _syncOnAirAfterRemoval(favorite);
    notifyListeners();
  }

  void replaceFavorites(List<Favorite> newFavorites) {
    // Compute diffs before replacing so we can keep the on-air list in sync
    final List<Favorite> previous = List<Favorite>.from(favorites);
    final List<Favorite> added = newFavorites
        .where(
            (nf) => !previous.any((pf) => pf.type == nf.type && pf.id == nf.id))
        .toList();
    final List<Favorite> removed = previous
        .where((pf) =>
            !newFavorites.any((nf) => nf.type == pf.type && nf.id == pf.id))
        .toList();

    favorites
      ..clear()
      ..addAll(newFavorites);
    storageData.save(SaveDataType.favorites, favorites);

    // Apply on-air updates for removed, then added
    for (final f in removed) {
      _syncOnAirAfterRemoval(f);
    }
    for (final f in added) {
      _syncOnAirAfterAddition(f);
    }
    notifyListeners();
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

  void updateNowPlayingIds(int? songId, int? artistId) {
    if (songId != null) {
      nowPlaying.songId = songId;
    }
    if (artistId != null) {
      nowPlaying.artistId = artistId;
    }
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
    int? newSongId,
    int? newArtistId,
    int catId,
    int channel,
    int sid,
    Uint8List programId,
    List<int> img,
  ) {
    logger.d(
        'Updating now playing with new data, SID: $sid, Channel: $channel, Program: $programId, SongId: $newSongId, ArtistId: $newArtistId');

    if (newStation.isNotEmpty) {
      updateNowPlayingChannelName(newStation);
    }
    updateNowPlayingSong(newSong);
    updateNowPlayingArtist(newArtist);
    updateNowPlayingIds(newSongId, newArtistId);
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

  ChannelData? getChannelDataForNowPlaying() {
    return sidMap[nowPlaying.sid];
  }

  ChannelData? getChannelDataForSid(int sid) {
    return sidMap[sid];
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

  // Favorites On Air helpers
  String _favoriteEntryKey(int sid, int matchedId, FavoriteType type) {
    return '$sid|$matchedId|${type.name}';
  }

  void _addFavoriteOnAirEntry({
    required int sid,
    required int channelNumber,
    required int matchedId,
    required FavoriteType type,
    Duration ttl = const Duration(minutes: 5),
  }) {
    final String key = _favoriteEntryKey(sid, matchedId, type);

    // Update existing or add new
    final int existingIndex = _favoritesOnAirEntries.indexWhere(
        (e) => e.sid == sid && e.matchedId == matchedId && e.type == type);
    final FavoriteOnAirEntry entry = FavoriteOnAirEntry(
      sid: sid,
      channelNumber: channelNumber,
      matchedId: matchedId,
      type: type,
      startedAt: DateTime.now(),
    );
    if (existingIndex >= 0) {
      _favoritesOnAirEntries[existingIndex] = entry;
    } else {
      _favoritesOnAirEntries.add(entry);
    }

    // Reset TTL timer
    _favoritesOnAirTimers[key]?.cancel();
    _favoritesOnAirTimers[key] = Timer(ttl, () {
      _removeFavoriteOnAirEntry(sid: sid, matchedId: matchedId, type: type);
    });

    notifyListeners();
  }

  void _removeFavoriteOnAirEntry({
    required int sid,
    required int matchedId,
    required FavoriteType type,
  }) {
    final String key = _favoriteEntryKey(sid, matchedId, type);
    _favoritesOnAirTimers.remove(key)?.cancel();
    _favoritesOnAirEntries.removeWhere(
        (e) => e.sid == sid && e.matchedId == matchedId && e.type == type);
    notifyListeners();
  }

  // Keep Favorites On Air entries in sync when favorites are added/removed
  void _syncOnAirAfterAddition(Favorite favorite) {
    // Scan known channels and add entries where this favorite is currently airing
    for (final channel in sidMap.values) {
      if (favorite.isSong) {
        if (channel.airingSongId == favorite.id && channel.airingSongId != 0) {
          _addFavoriteOnAirEntry(
            sid: channel.sid,
            channelNumber: channel.channelNumber,
            matchedId: favorite.id,
            type: FavoriteType.song,
            ttl: const Duration(minutes: 1),
          );
        }
      } else if (favorite.isArtist) {
        if (channel.airingArtistId == favorite.id &&
            channel.airingArtistId != 0) {
          _addFavoriteOnAirEntry(
            sid: channel.sid,
            channelNumber: channel.channelNumber,
            matchedId: favorite.id,
            type: FavoriteType.artist,
            ttl: const Duration(minutes: 1),
          );
        }
      }
    }
  }

  void _syncOnAirAfterRemoval(Favorite favorite) {
    // Remove any existing on-air entries for this favorite across all SIDs
    final List<FavoriteOnAirEntry> toRemove = _favoritesOnAirEntries
        .where((e) => e.type == favorite.type && e.matchedId == favorite.id)
        .toList();
    for (final e in toRemove) {
      _removeFavoriteOnAirEntry(
        sid: e.sid,
        matchedId: e.matchedId,
        type: e.type,
      );
    }
  }
}

class PlaybackInfo {
  String channelName;
  String channelCategory;
  String songTitle;
  String artistTitle;
  int songId;
  int artistId;
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
    this.songId,
    this.artistId,
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
        songId = 0,
        artistId = 0,
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
