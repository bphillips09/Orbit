// Channel Data, represents a channel's metadata
class ChannelData {
  int sid;
  int channelNumber;
  int catId;
  String channelName;
  String currentArtist;
  String currentSong;
  int currentPid;
  String channelShortDescription;
  String channelLongDescription;
  List<int> similarSids;
  int currentSongId;
  int currentArtistId;

  ChannelData(this.sid, this.channelNumber, this.catId, this.channelName,
      {this.currentArtist = '',
      this.currentSong = '',
      this.currentPid = 0,
      this.channelShortDescription = '',
      this.channelLongDescription = '',
      List<int>? similarSids,
      this.currentSongId = 0,
      this.currentArtistId = 0})
      : similarSids = similarSids ?? <int>[];
}
