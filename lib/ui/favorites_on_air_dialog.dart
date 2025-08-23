// Favorites On Air dialog
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/sxi_commands.dart';
import 'package:orbit/helpers.dart';
import 'package:orbit/ui/channel_list_entry.dart';
import 'package:orbit/ui/favorites_manager.dart';

class FavoritesOnAirDialog extends StatefulWidget {
  final AppState appState;
  final DeviceLayer deviceLayer;

  const FavoritesOnAirDialog({
    super.key,
    required this.appState,
    required this.deviceLayer,
  });

  @override
  State<FavoritesOnAirDialog> createState() => _FavoritesOnAirDialogState();
}

class _FavoritesOnAirDialogState extends State<FavoritesOnAirDialog> {
  final Map<int, Uint8List> _sidLogoCache = {};

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.appState,
      builder: (context, _) {
        final entries = widget.appState.favoritesOnAirEntries;
        return AlertDialog(
          title: Row(
            children: [
              const Expanded(
                child: Text(
                  'Favorites On Air',
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            height: 520,
            child: entries.isEmpty
                ? const Center(child: Text('No favorites on air right now'))
                : ListView.separated(
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final e = entries[index];
                      final channel = widget.appState.sidMap[e.sid];
                      final logoBytes =
                          widget.appState.storageData.getImageForSid(e.sid);
                      final channelLogo = logoBytes.isEmpty
                          ? null
                          : (_sidLogoCache[e.sid] ??=
                              Uint8List.fromList(logoBytes));

                      // Album art for current program if available
                      final programId = channel?.currentPid ?? 0;
                      final trackBytes =
                          widget.appState.imageMap[e.sid]?[programId];
                      final trackArt = trackBytes == null
                          ? null
                          : Uint8List.fromList(trackBytes);

                      final bool isNowPlaying =
                          widget.appState.currentChannel == e.channelNumber;

                      return ChannelListEntry(
                        isNowPlaying: isNowPlaying,
                        albumArt: trackArt,
                        placeholder: Icon(
                          getCategoryIcon(
                            channel == null
                                ? ''
                                : (widget.appState.categories[channel.catId] ??
                                    ''),
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
                        onTap: () {
                          final cfgCmd = SXiSelectChannelCommand(
                            ChanSelectionType.tuneUsingChannelNumber,
                            e.channelNumber,
                            0xFF,
                            Overrides.all(),
                            AudioRoutingType.routeToAudio,
                          );
                          widget.deviceLayer.sendControlCommand(cfgCmd);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await FavoritesManagerDialogHelper.show(
                  context: context,
                  appState: widget.appState,
                  deviceLayer: widget.deviceLayer,
                );
              },
              child: const Text('Edit Favorites'),
            ),
          ],
        );
      },
    );
  }
}

class FavoritesOnAirDialogHelper {
  static Future<void> show({
    required BuildContext context,
    required AppState appState,
    required DeviceLayer deviceLayer,
  }) async {
    await showDialog<void>(
      barrierDismissible: true,
      context: context,
      builder: (context) => FavoritesOnAirDialog(
        appState: appState,
        deviceLayer: deviceLayer,
      ),
    );
  }
}
