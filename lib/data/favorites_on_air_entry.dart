// Favorites On Air entry model
import 'package:orbit/data/favorite.dart';

class FavoriteOnAirEntry {
  final int sid;
  final int channelNumber;
  final int matchedId;
  final FavoriteType type;
  final DateTime startedAt;

  const FavoriteOnAirEntry({
    required this.sid,
    required this.channelNumber,
    required this.matchedId,
    required this.type,
    required this.startedAt,
  });

  bool get isSong => type == FavoriteType.song;
  bool get isArtist => type == FavoriteType.artist;
}
