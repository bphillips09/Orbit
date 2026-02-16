import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/platform/head_unit_aux.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/ui/preset.dart' show computeNextPresetSid;
import 'package:orbit/sxi_commands.dart';
import 'package:path_provider/path_provider.dart';
import 'package:orbit/logging.dart';
import 'package:orbit/platform/now_playing_indicator.dart';

class AudioServiceHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  DeviceLayer deviceLayer;
  AppState appState;

  AudioServiceHandler(this.deviceLayer, this.appState);

  Uri? currentAlbumUri;
  Uint8List? lastProgram;
  PlaybackInfo? nowPlaying;
  File? albumArt;
  Directory? cacheDir;
  AppPlaybackState? _lastPlaybackState;

  @override
  Future<void> play() async {
    logger.d('---> PLAY');
    deviceLayer.sendControlCommand(
        SXiInstantReplayPlaybackControlCommand(PlaybackControlType.play, 0, 0));
  }

  @override
  Future<void> pause() async {
    logger.d('---> PAUSE');
    deviceLayer.sendControlCommand(SXiInstantReplayPlaybackControlCommand(
        PlaybackControlType.pause, 0, 0));
  }

  @override
  Future<void> stop() async {
    logger.d('---> STOP');
    deviceLayer.sendControlCommand(SXiInstantReplayPlaybackControlCommand(
        PlaybackControlType.pause, 0, 0));
  }

  @override
  Future<void> skipToPrevious() async {
    logger.d('---> PREV |<');
    switch (appState.mediaKeyBehavior) {
      case MediaKeyBehavior.channel:
        final ch =
            nowPlaying?.channelNumber ?? appState.nowPlaying.channelNumber;
        if (ch <= 0) {
          logger.w('Skip previous ignored: current channel unknown');
          return;
        }
        deviceLayer.sendControlCommand(SXiSelectChannelCommand(
            ChanSelectionType.tuneToNextLowerChannelNumberInCategory,
            ch,
            0xFF,
            ChannelAttributes.all(),
            AudioRoutingType.routeToAudio));
        break;
      case MediaKeyBehavior.presetCycle:
        cyclePreset(left: true);
        break;
      case MediaKeyBehavior.track:
        await rewind();
        break;
    }
  }

  @override
  Future<void> skipToNext() async {
    logger.d('---> NEXT >|');
    switch (appState.mediaKeyBehavior) {
      case MediaKeyBehavior.channel:
        final ch =
            nowPlaying?.channelNumber ?? appState.nowPlaying.channelNumber;
        if (ch <= 0) {
          logger.w('Skip next ignored: current channel unknown');
          return;
        }
        deviceLayer.sendControlCommand(SXiSelectChannelCommand(
            ChanSelectionType.tuneToNextHigherChannelNumberInCategory,
            ch,
            0xFF,
            ChannelAttributes.all(),
            AudioRoutingType.routeToAudio));
        break;
      case MediaKeyBehavior.presetCycle:
        cyclePreset(left: false);
        break;
      case MediaKeyBehavior.track:
        await fastForward();
        break;
    }
  }

  @override
  Future<void> rewind() async {
    logger.d('---> PREV <<');
    if (appState.isScanActive) {
      final cfgCmd = SXiSelectChannelCommand(
          ChanSelectionType.skipBackToPreviousScanItem,
          0,
          appState.currentCategory,
          ChannelAttributes.all(),
          AudioRoutingType.routeToAudio);
      deviceLayer.sendControlCommand(cfgCmd);
    } else {
      deviceLayer.sendControlCommand(SXiInstantReplayPlaybackControlCommand(
          PlaybackControlType.previousResume, 0, 0));
    }
  }

  @override
  Future<void> fastForward() async {
    logger.d('---> NEXT >>');
    if (appState.isScanActive) {
      final cfgCmd = SXiSelectChannelCommand(
          ChanSelectionType.skipForwardToNextScanItem,
          0,
          appState.currentCategory,
          ChannelAttributes.all(),
          AudioRoutingType.routeToAudio);
      deviceLayer.sendControlCommand(cfgCmd);
    } else {
      deviceLayer.sendControlCommand(SXiInstantReplayPlaybackControlCommand(
          PlaybackControlType.nextResume, 0, 0));
    }
  }

  void cyclePreset({required bool left}) {
    final int? targetSid = computeNextPresetSid(appState, left: left);
    if (targetSid == null) {
      logger.t('No presets to cycle');
      return;
    }
    logger.d('Cycling preset to SID=$targetSid');
    final cfgCmd = SXiSelectChannelCommand(
      ChanSelectionType.tuneUsingSID,
      targetSid,
      0xFF,
      ChannelAttributes.all(),
      AudioRoutingType.routeToAudio,
    );
    deviceLayer.sendControlCommand(cfgCmd);
  }

  void goToLive() {
    deviceLayer.sendControlCommand(
        SXiInstantReplayPlaybackControlCommand(PlaybackControlType.live, 0, 0));
  }

  @override
  Future<void> seek(Duration position) async {
    logger.d('---> SEEK (to ${position.inSeconds})');
    deviceLayer.sendControlCommand(
      SXiInstantReplayPlaybackControlCommand(
        PlaybackControlType.jumpToTimeOffsetResume,
        (position.inSeconds - appState.playbackTimeBefore).round(),
        0,
      ),
    );
  }

  void onPlaybackStateChanged(AppPlaybackState appPlaybackState) {
    logger.d('---> Process State Change');
    bool playing = appPlaybackState == AppPlaybackState.live ||
        appPlaybackState == AppPlaybackState.recordedContent;

    // Switch head unit to aux when system transitions to playing
    final bool wasPlaying = _lastPlaybackState == AppPlaybackState.live ||
        _lastPlaybackState == AppPlaybackState.recordedContent;
    _lastPlaybackState = appPlaybackState;
    if (!wasPlaying &&
        playing &&
        defaultTargetPlatform == TargetPlatform.android &&
        appState.useNativeAuxInput &&
        HeadUnitAux.isAvailable) {
      unawaited(HeadUnitAux.trySwitchToAux());
    }

    // Ensure browser tab shows as playing on web if there's any audio
    NowPlayingIndicator.update(isPlaying: true);

    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.stop,
      MediaControl.skipToNext,
    ];

    playbackState.add(playbackState.value.copyWith(
      controls: controls,
      systemActions: {
        MediaAction.seek,
      },
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: Duration(seconds: appState.playbackTimeBefore.toInt()),
      speed: 1,
    ));
  }

  void onPlaybackInfoChanged(PlaybackInfo playbackInfo) async {
    if (!listEquals(lastProgram, playbackInfo.programId)) {
      logger.t('Loading Album Art for Native Platform');
      currentAlbumUri = await updateAlbumArt(playbackInfo);
    }

    nowPlaying = playbackInfo;
    lastProgram = playbackInfo.programId;

    mediaItem.add(MediaItem(
        id: '1',
        title: playbackInfo.songTitle,
        artist: playbackInfo.artistTitle,
        album: playbackInfo.channelName,
        artUri: currentAlbumUri,
        isLive: playbackInfo.state == AppPlaybackState.live,
        duration: Duration(
            seconds:
                appState.playbackTimeBefore + appState.playbackTimeRemaining)));
  }

  Future<Uri?> updateAlbumArt(PlaybackInfo playbackInfo) async {
    final programId = playbackInfo.programId;
    Uint8List image = playbackInfo.image;

    // Fallback to channel image if program image missing
    if (image.isEmpty && playbackInfo.channelImage.isNotEmpty) {
      image = playbackInfo.channelImage;
    }

    // On web/wasm, provide a data URI so Media Session artwork can display
    if (image.isNotEmpty && (kIsWeb || kIsWasm)) {
      try {
        final dataUri = 'data:image/jpeg;base64,${base64Encode(image)}';
        return Uri.parse(dataUri);
      } catch (_) {
        return null;
      }
    }

    if (image.isNotEmpty && !kIsWeb && !kIsWasm) {
      if (albumArt == null || cacheDir == null) {
        cacheDir = await getApplicationCacheDirectory();

        albumArt = File('${cacheDir?.path}/${programId.join()}.jpg');
      } else {
        albumArt =
            await albumArt?.rename('${cacheDir?.path}/${programId.join()}.jpg');
      }

      var writtenFile = await albumArt?.writeAsBytes(image);
      return writtenFile?.uri;
    }

    return null;
  }
}
