// Event emitted when a favorite goes on air
import 'package:orbit/data/favorite.dart';

class FavoriteOnAirEvent {
  final FavoriteType type;
  final int matchedId;
  final int sid;
  final int channelNumber;

  const FavoriteOnAirEvent({
    required this.type,
    required this.matchedId,
    required this.sid,
    required this.channelNumber,
  });

  @override
  String toString() {
    return 'FavoriteOnAirEvent(type: $type, matchedId: $matchedId, sid: $sid, channelNumber: $channelNumber)';
  }
}
