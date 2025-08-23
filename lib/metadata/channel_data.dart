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
  int airingSongId;
  int airingArtistId;

  ChannelData(this.sid, this.channelNumber, this.catId, this.channelName,
      {this.currentArtist = '',
      this.currentSong = '',
      this.currentPid = 0,
      this.channelShortDescription = '',
      this.channelLongDescription = '',
      List<int>? similarSids,
      this.airingSongId = 0,
      this.airingArtistId = 0})
      : similarSids = similarSids ?? <int>[];
}
