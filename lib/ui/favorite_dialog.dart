// Add Favorite Dialog
import 'package:flutter/material.dart';
import 'package:orbit/app_state.dart';
import 'package:orbit/device_layer.dart';
import 'package:orbit/data/favorite.dart';
import 'package:orbit/ui/favorites_manager.dart';

enum FavoriteTarget { song, artist }

class FavoriteDialogHelper {
  static Future<void> show({
    required BuildContext context,
    required AppState appState,
    required DeviceLayer deviceLayer,
  }) async {
    // Snapshot all values up-front so the dialog stays static even if
    // now playing metadata changes while it's open.
    final int songId = appState.nowPlaying.songId;
    final int artistId = appState.nowPlaying.artistId;

    final bool currentSongCanBeAdded = songId != 0;
    final bool currentArtistCanBeAdded = artistId != 0;
    final bool currentSongIsChannelTitle =
        songId == 0xFFFF || songId == 0xFFFFFFFF;
    final bool currentArtistIsChannelTitle =
        artistId == 0xFFFF || artistId == 0xFFFFFFFF;

    final bool isValidArtist =
        currentArtistCanBeAdded && !currentArtistIsChannelTitle;
    final bool isValidSong =
        currentSongCanBeAdded && !currentSongIsChannelTitle && isValidArtist;

    final bool isSongFavorited = appState.isNowPlayingSongFavorited();
    final bool isArtistFavorited = appState.isNowPlayingArtistFavorited();
    final bool isSongCapacityReached =
        appState.isAtCapacityForType(FavoriteType.song);
    final bool isArtistCapacityReached =
        appState.isAtCapacityForType(FavoriteType.artist);
    final bool canAddArtist =
        isValidArtist && !isArtistFavorited && !isArtistCapacityReached;
    final bool canAddSong =
        isValidSong && !isSongFavorited && !isSongCapacityReached;

    // Snapshot the now-playing titles at open time so they don't change
    final String initialSongTitle = appState.nowPlaying.songTitle;
    final String initialArtistTitle = appState.nowPlaying.artistTitle;

    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        String getCannotFavoriteSongReason() {
          if (isSongFavorited) {
            return 'Favorited';
          }
          if (isSongCapacityReached) {
            return 'Limit reached';
          }
          if (currentSongIsChannelTitle) {
            return 'Can\'t add this program';
          } else if (!isValidSong) {
            return 'Can\'t add this song';
          }
          return '';
        }

        String getCannotFavoriteArtistReason() {
          if (isArtistFavorited) {
            return 'Favorited';
          }
          if (isArtistCapacityReached) {
            return 'Limit reached';
          }
          if (currentArtistIsChannelTitle) {
            return 'Can\'t add this program';
          } else if (!isValidArtist) {
            return 'Can\'t add this artist';
          }
          return '';
        }

        void addAndSend({required bool song}) {
          if (song) {
            if (!isValidSong || isSongFavorited || isSongCapacityReached) {
              if (isSongCapacityReached) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Song favorites limit (60) reached'),
                  ),
                );
              }
              return;
            }
            appState.addFavorite(Favorite(
              type: FavoriteType.song,
              id: songId,
              artistName: initialArtistTitle,
              songName: initialSongTitle,
            ));
          } else {
            if (!isValidArtist ||
                isArtistFavorited ||
                isArtistCapacityReached) {
              if (isArtistCapacityReached) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Artist favorites limit (60) reached'),
                  ),
                );
              }
              return;
            }
            appState.addFavorite(Favorite(
              type: FavoriteType.artist,
              id: artistId,
              artistName: initialArtistTitle,
            ));
          }

          try {
            // Send only the new favorite instead of resending the entire list
            if (song) {
              deviceLayer.addFavorites([songId], []);
            } else {
              deviceLayer.addFavorites([], [artistId]);
            }
            ScaffoldMessenger.of(dialogContext).showSnackBar(
              SnackBar(
                content: Text(
                    '"${song ? initialSongTitle : initialArtistTitle}" added to favorites'),
              ),
            );
          } catch (_) {}

          Navigator.of(dialogContext).pop();
        }

        return AlertDialog(
          title: Row(
            children: [
              const Expanded(
                child: Text(
                  'Add Favorite',
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.music_note),
                trailing: canAddSong ? const Icon(Icons.add) : null,
                title: Text(
                  initialSongTitle.isEmpty ? 'Current Song' : initialSongTitle,
                ),
                subtitle: Text(
                    'Song${!isValidSong || isSongFavorited || isSongCapacityReached ? ' (${getCannotFavoriteSongReason()})' : ''}'),
                enabled: canAddSong,
                onTap: canAddSong ? () => addAndSend(song: true) : null,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.person),
                trailing: canAddArtist ? const Icon(Icons.add) : null,
                title: Text(
                  initialArtistTitle.isEmpty
                      ? 'Current Artist'
                      : initialArtistTitle,
                ),
                subtitle: Text(
                    'Artist${!isValidArtist || isArtistFavorited || isArtistCapacityReached ? ' (${getCannotFavoriteArtistReason()})' : ''}'),
                enabled: canAddArtist,
                onTap: canAddArtist ? () => addAndSend(song: false) : null,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                // If the current song or artist is already favorited, deep-link to it
                FavoriteType? tab;
                FavoriteType? focusType;
                int? focusId;
                if (isSongFavorited) {
                  tab = FavoriteType.song;
                  focusType = FavoriteType.song;
                  focusId = songId;
                } else if (isArtistFavorited) {
                  tab = FavoriteType.artist;
                  focusType = FavoriteType.artist;
                  focusId = artistId;
                }
                await FavoritesManagerDialogHelper.show(
                  context: context,
                  appState: appState,
                  deviceLayer: deviceLayer,
                  showTab: tab,
                  focusType: focusType,
                  focusId: focusId,
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
