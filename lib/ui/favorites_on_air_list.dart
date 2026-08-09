// Favorites On Air list content
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/data/favorites_on_air_entry.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/ui/channel_list_entry.dart';
import 'package:orbit/ui/favorites_manager.dart';

class FavoritesOnAirList extends StatefulWidget {
  final AppState appState;
  final DeviceLayer deviceLayer;
  final VoidCallback? onAfterTune;

  const FavoritesOnAirList({
    super.key,
    required this.appState,
    required this.deviceLayer,
    this.onAfterTune,
  });

  @override
  State<FavoritesOnAirList> createState() => _FavoritesOnAirListState();
}

class _FavoritesOnAirListState extends State<FavoritesOnAirList> {
  final Map<int, Uint8List> _sidLogoCache = {};

  List<FavoriteOnAirEntry> _buildDedupedEntries() {
    final entries = widget.appState.favoritesOnAirEntries;
    // If both song and artist are present for the same channel, prefer showing the song entry
    final Map<String, FavoriteOnAirEntry> uniqueMap = {};
    for (final e in entries) {
      final key = '${e.sid}|${e.channelNumber}';
      final existing = uniqueMap[key];
      if (existing == null) {
        uniqueMap[key] = e;
      } else if (existing.isArtist && e.isSong) {
        uniqueMap[key] = e;
      }
    }
    return uniqueMap.values.toList();
  }

  void _tuneToEntry(FavoriteOnAirEntry entry) {
    if (widget.appState.dismissOnAirFavoritesOnSelect) {
      widget.onAfterTune?.call();
    }
    final cfgCmd = SXiSelectChannelCommand(
      ChanSelectionType.tuneUsingChannelNumber,
      entry.channelNumber,
      0xFF,
      ChannelAttributes.all(),
      AudioRoutingType.routeToAudio,
    );
    widget.deviceLayer.sendControlCommand(cfgCmd);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final List<FavoriteOnAirEntry> deduped = _buildDedupedEntries();
        if (deduped.isEmpty) {
          return const Center(child: Text('No favorites on air right now'));
        }
        return ListView.separated(
          itemCount: deduped.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final e = deduped[index];
            final channel = widget.appState.sidMap[e.sid];
            final logoBytes = widget.appState.storageData.getImageForSid(e.sid);
            final channelLogo = logoBytes.isEmpty
                ? null
                : (_sidLogoCache[e.sid] ??= Uint8List.fromList(logoBytes));

            final programId = channel?.currentPid ?? 0;
            final trackBytes = widget.appState.imageMap[e.sid]?[programId];
            final trackArt =
                trackBytes == null ? null : Uint8List.fromList(trackBytes);

            final bool isNowPlaying =
                widget.appState.currentChannel == e.channelNumber;

            return ChannelListEntry(
              isNowPlaying: isNowPlaying,
              albumArt: trackArt,
              placeholder: Icon(
                getCategoryIcon(
                  channel == null
                      ? ''
                      : (widget.appState.categories[channel.catId] ?? ''),
                ),
                size: 22,
              ),
              titleText: channel?.currentSong ?? '',
              subtitleText: channel?.currentArtist ?? '',
              channelNumber: e.channelNumber,
              channelLogo: channelLogo,
              channelName: channel?.channelName ?? '',
              infoButton: IconButton(
                tooltip: 'Edit favorite',
                icon: const Icon(Icons.list),
                onPressed: () async {
                  await FavoritesManagerDialogHelper.show(
                    context: context,
                    appState: widget.appState,
                    deviceLayer: widget.deviceLayer,
                    showTab: e.type,
                    focusType: e.type,
                    focusId: e.matchedId,
                  );
                },
              ),
              onTap: () => _tuneToEntry(e),
            );
          },
        );
      },
    );
  }
}
