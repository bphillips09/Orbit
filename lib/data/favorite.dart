// Favorite model for artist/song favorites
enum FavoriteType { song, artist }

class Favorite {
  final FavoriteType type;
  final int id;
  final String artistName;
  final String? songName;

  const Favorite({
    required this.type,
    required this.id,
    required this.artistName,
    this.songName,
  });

  bool get isSong => type == FavoriteType.song;
  bool get isArtist => type == FavoriteType.artist;

  String get displayPrimary {
    return isSong ? (songName ?? '') : artistName;
  }

  String get displaySecondary {
    return isSong ? artistName : '';
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'type': type.name,
      'id': id,
      'artistName': artistName,
      'songName': songName,
    };
  }

  static Favorite fromMap(Map<String, dynamic> map) {
    final String typeStr = (map['type'] ?? 'artist').toString();
    final FavoriteType type = typeStr == FavoriteType.song.name
        ? FavoriteType.song
        : FavoriteType.artist;
    return Favorite(
      type: type,
      id: map['id'] is int
          ? map['id'] as int
          : int.tryParse(map['id']?.toString() ?? '0') ?? 0,
      artistName: (map['artistName'] ?? '').toString(),
      songName: map['songName']?.toString(),
    );
  }

  @override
  String toString() {
    return 'Favorite(type: ${type.name}, id: $id, artist: $artistName, song: ${songName ?? ''})';
  }
}
