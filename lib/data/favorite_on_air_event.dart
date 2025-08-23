// Event emitted when a favorite goes on air
import 'package:orbit/data/favorite.dart';

class FavoriteOnAirEvent {
  final FavoriteType type;
  final int matchedId;
  final int sid;
  final int channelNumber;
  final String? artistName;
  final String? songName;

  const FavoriteOnAirEvent({
    required this.type,
    required this.matchedId,
    required this.sid,
    required this.channelNumber,
    this.artistName,
    this.songName,
  });
}
