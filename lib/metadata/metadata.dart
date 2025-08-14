// Track Metadata Item (TMI)
// Channel Metadata Item (CMI)
// Global Metadata Item (GMI)
// parsers and helpers
import 'dart:convert';
import 'package:orbit/sxi_command_types.dart';
import 'package:orbit/logging.dart';

String decodeTextBytes(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    try {
      return latin1.decode(bytes);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }
}

int advanceOverNullTerminated(List<int> bytes, int start) {
  int i = start;
  while (i < bytes.length && bytes[i] != 0x00) {
    i++;
  }
  if (i < bytes.length) i++; // consume null terminator
  return i;
}

int advanceOverCmiItems(List<int> bytes, int start, int itemCount) {
  int i = start;
  for (int n = 0; n < itemCount; n++) {
    if (i + 1 >= bytes.length) return bytes.length;
    final int tag = (bytes[i] << 8) | bytes[i + 1];
    i += 2;
    try {
      switch (ChannelMetadataIdentifier.getByValue(tag)) {
        case ChannelMetadataIdentifier.channelShortDescription:
        case ChannelMetadataIdentifier.channelLongDescription:
          i = advanceOverNullTerminated(bytes, i);
          break;
        case ChannelMetadataIdentifier.similarChannelList:
          if (i + 3 >= bytes.length) return bytes.length;
          int count = (bytes[i] << 24) |
              (bytes[i + 1] << 16) |
              (bytes[i + 2] << 8) |
              bytes[i + 3];
          i += 4;
          int bytesToSkip = count * 2;
          if (i + bytesToSkip > bytes.length) return bytes.length;
          i += bytesToSkip;
          break;
        case ChannelMetadataIdentifier.channelListOrder:
          if (i + 1 >= bytes.length) return bytes.length;
          i += 2;
          break;
      }
    } catch (_) {
      // Unknown tag; we can't safely parse length, stop advancing here
      return i;
    }
  }
  return i;
}

int advanceOverTmiItems(List<int> bytes, int start, int itemCount) {
  int i = start;
  for (int n = 0; n < itemCount; n++) {
    if (i + 1 >= bytes.length) return bytes.length;
    final int tag = (bytes[i] << 8) | bytes[i + 1];
    i += 2;
    try {
      switch (TrackMetadataIdentifier.getByValue(tag)) {
        case TrackMetadataIdentifier.songId:
        case TrackMetadataIdentifier.artistId:
        case TrackMetadataIdentifier.itunesSongId:
          if (i + 3 >= bytes.length) return bytes.length;
          i += 4;
          break;
        case TrackMetadataIdentifier.songName:
        case TrackMetadataIdentifier.artistName:
        case TrackMetadataIdentifier.currentInfo:
          i = advanceOverNullTerminated(bytes, i);
          break;
        case TrackMetadataIdentifier.sportBroadcastId:
        case TrackMetadataIdentifier.leagueBroadcastId:
        case TrackMetadataIdentifier.trafficCityId:
          if (i >= bytes.length) return bytes.length;
          i += 1;
          break;
        case TrackMetadataIdentifier.gameTeamId:
          if (i + 3 >= bytes.length) return bytes.length;
          int count = (bytes[i] << 24) |
              (bytes[i + 1] << 16) |
              (bytes[i + 2] << 8) |
              bytes[i + 3];
          i += 4;
          int bytesToSkip = count * 2;
          if (i + bytesToSkip > bytes.length) return bytes.length;
          i += bytesToSkip;
          break;
      }
    } catch (_) {
      // Unknown tag; we can't safely parse length, stop advancing here
      return i;
    }
  }
  return i;
}

List<int> readCmiBlockFrom(int nextIndex, List<int> frame) {
  final int count = (nextIndex < frame.length) ? frame[nextIndex] : 0;
  int i = nextIndex + 1;
  final int start = i;
  if (count <= 0 || i > frame.length) {
    return <int>[];
  }
  i = advanceOverCmiItems(frame, i, count);
  return (start <= i && start <= frame.length)
      ? frame.sublist(start, i)
      : <int>[];
}

List<int> readTmiBlockFrom(int nextIndex, List<int> frame) {
  final int count = (nextIndex < frame.length) ? frame[nextIndex] : 0;
  int i = nextIndex + 1;
  final int start = i;
  if (count <= 0 || i > frame.length) {
    return <int>[];
  }
  i = advanceOverTmiItems(frame, i, count);
  return (start <= i && start <= frame.length)
      ? frame.sublist(start, i)
      : <int>[];
}

bool logMetadata = false;

class TrackMetadataItem {
  final TrackMetadataIdentifier identifier;
  final dynamic value;

  TrackMetadataItem(this.identifier, this.value);

  static List<TrackMetadataItem> parseTrackMetadata(List<int> tmTagValue) {
    List<TrackMetadataItem> items = [];
    int index = 0;

    if (logMetadata) {
      logger.t(
          '--------------- TMI Parser: Processing ${tmTagValue.length} bytes ---------------');
    }

    while (index < tmTagValue.length) {
      if (logMetadata) {
        logger.t('TMI Parser: At index $index/${tmTagValue.length}');
      }
      // Require 2 bytes for the 16-bit TMI tag header (big-endian)
      if (index + 1 >= tmTagValue.length) {
        logger.t('TMI Parser: Incomplete TMI tag header; stopping parse');
        break;
      }

      // Parse TMI tag (16-bit)
      int tmiTag = (tmTagValue[index] << 8) | tmTagValue[index + 1];
      if (logMetadata) {
        logger.t(
            'TMI Parser: Found 16-bit TMI tag: $tmiTag (0x${tmiTag.toRadixString(16).padLeft(4, '0').toUpperCase()})');
      }
      index += 2;

      if (index >= tmTagValue.length) break;

      try {
        TrackMetadataIdentifier identifier =
            TrackMetadataIdentifier.getByValue(tmiTag);
        if (logMetadata) {
          logger.t(
              'TMI Parser: Identified 16-bit tag as ${identifier.toString().split('.').last}');
        }
        dynamic parsedValue;

        switch (identifier) {
          case TrackMetadataIdentifier.songId:
            if (index + 3 < tmTagValue.length) {
              parsedValue = (tmTagValue[index] << 24) |
                  (tmTagValue[index + 1] << 16) |
                  (tmTagValue[index + 2] << 8) |
                  tmTagValue[index + 3];
              index += 4;
              if (logMetadata) {
                logger.t('TMI Parser: Parsed songId: $parsedValue');
              }
            } else {
              if (logMetadata) {
                logger.t(
                    'TMI Parser: Not enough bytes for songId (need 4, have ${tmTagValue.length - index})');
              }
            }
            break;

          case TrackMetadataIdentifier.artistId:
            if (index + 3 < tmTagValue.length) {
              parsedValue = (tmTagValue[index] << 24) |
                  (tmTagValue[index + 1] << 16) |
                  (tmTagValue[index + 2] << 8) |
                  tmTagValue[index + 3];
              index += 4;
              if (logMetadata) {
                logger.t('TMI Parser: Parsed artistId: $parsedValue');
              }
            } else {
              if (logMetadata) {
                logger.t(
                    'TMI Parser: Not enough bytes for artistId (need 4, have ${tmTagValue.length - index})');
              }
            }
            break;

          case TrackMetadataIdentifier.songName:
          case TrackMetadataIdentifier.artistName:
          case TrackMetadataIdentifier.currentInfo:
            if (index < tmTagValue.length) {
              List<int> stringBytes = [];
              while (index < tmTagValue.length && tmTagValue[index] != 0) {
                stringBytes.add(tmTagValue[index]);
                index++;
              }
              if (index < tmTagValue.length && tmTagValue[index] == 0) {
                index++; // Skip null terminator
              }
              parsedValue = decodeTextBytes(stringBytes);
              if (logMetadata) {
                logger.t('TMI Parser: Parsed string: "$parsedValue"');
              }
            }
            break;

          case TrackMetadataIdentifier.sportBroadcastId:
          case TrackMetadataIdentifier.leagueBroadcastId:
          case TrackMetadataIdentifier.trafficCityId:
            if (index < tmTagValue.length) {
              parsedValue = tmTagValue[index];
              index++;
            }
            break;

          case TrackMetadataIdentifier.itunesSongId:
            if (index + 3 < tmTagValue.length) {
              parsedValue = (tmTagValue[index] << 24) |
                  (tmTagValue[index + 1] << 16) |
                  (tmTagValue[index + 2] << 8) |
                  tmTagValue[index + 3];
              index += 4;
              if (logMetadata) {
                logger.t('TMI Parser: Parsed itunesSongId: $parsedValue');
              }
            }
            break;

          case TrackMetadataIdentifier.gameTeamId:
            if (index + 3 < tmTagValue.length) {
              int count = (tmTagValue[index] << 24) |
                  (tmTagValue[index + 1] << 16) |
                  (tmTagValue[index + 2] << 8) |
                  tmTagValue[index + 3];
              index += 4;
              if (logMetadata) {
                logger.t('TMI Parser: Game team count: $count');
              }

              List<int> teamIds = [];
              for (int i = 0; i < count && index + 1 < tmTagValue.length; i++) {
                int teamId = (tmTagValue[index] << 8) | tmTagValue[index + 1];
                teamIds.add(teamId);
                index += 2;
                if (logMetadata) {
                  logger.t('TMI Parser: Team ID $i: $teamId');
                }
              }
              parsedValue = teamIds;
            }
            break;
        }

        if (parsedValue != null) {
          items.add(TrackMetadataItem(identifier, parsedValue));
        }
      } catch (e) {
        // Skip unknown TMI tags but continue parsing
        if (logMetadata) {
          logger.t(
              'TMI Parser: Unknown 16-bit TMI tag: $tmiTag (0x${tmiTag.toRadixString(16).padLeft(4, '0').toUpperCase()}) - $e');
        }
        // Stop parsing further on unknown tag
        break;
      }
    }

    if (logMetadata) {
      logger.t(
          '--------------- TMI Parser: Completed, found ${items.length} items ---------------');
    }
    return items;
  }

  @override
  String toString() {
    String identifierName = identifier.toString().split('.').last;
    return 'TMI $identifierName: $value';
  }
}

class ChannelMetadataItem {
  final ChannelMetadataIdentifier identifier;
  final dynamic value;

  ChannelMetadataItem(this.identifier, this.value);

  static List<ChannelMetadataItem> parseChannelMetadata(List<int> cmTagValue) {
    List<ChannelMetadataItem> items = [];
    int index = 0;

    if (logMetadata) {
      logger.t(
          '--------------- CMI Parser: Processing ${cmTagValue.length} bytes: $cmTagValue ---------------');
    }

    while (index < cmTagValue.length) {
      if (logMetadata) {
        logger.t('CMI Parser: At index $index/${cmTagValue.length}');
      }

      // Require 2 bytes for the 16-bit CMI tag header (big-endian)
      if (index + 1 >= cmTagValue.length) {
        logger.t('CMI Parser: Incomplete CMI tag header; stopping parse');
        break;
      }

      int cmiTag = (cmTagValue[index] << 8) | cmTagValue[index + 1];
      if (logMetadata) {
        logger.t(
            'CMI Parser: Found 16-bit CMI tag: $cmiTag (0x${cmiTag.toRadixString(16).padLeft(4, '0').toUpperCase()})');
      }
      index += 2;

      if (index >= cmTagValue.length) break;

      try {
        ChannelMetadataIdentifier identifier =
            ChannelMetadataIdentifier.getByValue(cmiTag);
        if (logMetadata) {
          logger.t(
              'CMI Parser: Identified 16-bit tag as ${identifier.toString().split('.').last}');
        }
        dynamic parsedValue;

        switch (identifier) {
          case ChannelMetadataIdentifier.channelShortDescription:
          case ChannelMetadataIdentifier.channelLongDescription:
            // Parse null-terminated string
            if (index < cmTagValue.length) {
              List<int> stringBytes = [];
              while (index < cmTagValue.length && cmTagValue[index] != 0) {
                stringBytes.add(cmTagValue[index]);
                index++;
              }
              if (index < cmTagValue.length && cmTagValue[index] == 0) {
                index++; // Skip null terminator
              }
              parsedValue = decodeTextBytes(stringBytes);
              if (logMetadata) {
                logger.t('CMI Parser: Parsed string: "$parsedValue"');
              }
            }
            break;

          case ChannelMetadataIdentifier.similarChannelList:
            // Read count (32-bit), clamp to max 8 entries
            if (index + 3 < cmTagValue.length) {
              int count = (cmTagValue[index] << 24) |
                  (cmTagValue[index + 1] << 16) |
                  (cmTagValue[index + 2] << 8) |
                  cmTagValue[index + 3];
              index += 4;
              if (count > 8) count = 8;
              if (logMetadata) {
                logger.t('CMI Parser: Similar channel count (clamped): $count');
              }

              List<int> channelIds = [];
              for (int i = 0; i < count; i++) {
                if (index + 1 >= cmTagValue.length) {
                  logger.t(
                      'CMI Parser: Not enough bytes for channel id $i (need 2)');
                  break;
                }
                int channelId =
                    (cmTagValue[index] << 8) | cmTagValue[index + 1];
                channelIds.add(channelId);
                index += 2;
                if (logMetadata) {
                  logger.t('CMI Parser: Similar channel $i: $channelId');
                }
              }
              parsedValue = channelIds;
            } else {
              if (logMetadata) {
                logger.t(
                    'CMI Parser: Not enough bytes for similarChannelList count (need 4)');
              }
            }
            break;

          case ChannelMetadataIdentifier.channelListOrder:
            if (index + 1 < cmTagValue.length) {
              int order = (cmTagValue[index] << 8) | cmTagValue[index + 1];
              index += 2;
              parsedValue = order;
              if (logMetadata) {
                logger.t('CMI Parser: Parsed channelListOrder: $parsedValue');
              }
            } else {
              if (logMetadata) {
                logger.t(
                    'CMI Parser: Not enough bytes for channelListOrder (need 2)');
              }
            }
            break;
        }

        if (parsedValue != null) {
          items.add(ChannelMetadataItem(identifier, parsedValue));
        }
      } catch (e) {
        // Stop parsing on unknown CMI tag
        if (logMetadata) {
          logger.t(
              'CMI Parser: Unknown 16-bit CMI tag: $cmiTag (0x${cmiTag.toRadixString(16).padLeft(4, '0').toUpperCase()}) - $e');
        }
        break;
      }
    }

    if (logMetadata) {
      logger.t(
          '--------------- CMI Parser: Completed, found ${items.length} items ---------------');
    }
    return items;
  }

  @override
  String toString() {
    String identifierName = identifier.toString().split('.').last;
    return 'CMI $identifierName: $value';
  }
}

class GlobalMetadataItem {
  final GlobalMetadataIdentifier identifier;
  final dynamic value;

  GlobalMetadataItem(this.identifier, this.value);

  static List<GlobalMetadataItem> parseGlobalMetadata(List<int> gmTagValue) {
    List<GlobalMetadataItem> items = [];
    int index = 0;

    if (logMetadata) {
      logger.t(
          '--------------- GMI Parser: Processing ${gmTagValue.length} bytes: $gmTagValue ---------------');
    }

    while (index < gmTagValue.length) {
      if (logMetadata) {
        logger.t('GMI Parser: At index $index/${gmTagValue.length}');
      }

      // Require 2 bytes for the 16-bit GMI tag header (big-endian)
      if (index + 1 >= gmTagValue.length) {
        logger.t('GMI Parser: Incomplete GMI tag header; stopping parse');
        break;
      }

      int gmiTag = (gmTagValue[index] << 8) | gmTagValue[index + 1];
      if (logMetadata) {
        logger.t(
            'GMI Parser: Found 16-bit GMI tag: $gmiTag (0x${gmiTag.toRadixString(16).padLeft(4, '0').toUpperCase()})');
      }
      index += 2;

      if (index >= gmTagValue.length) break;

      try {
        GlobalMetadataIdentifier identifier =
            GlobalMetadataIdentifier.getByValue(gmiTag);
        if (logMetadata) {
          logger.t(
              'GMI Parser: Identified 16-bit tag as ${identifier.toString().split('.').last}');
        }
        dynamic parsedValue;

        switch (identifier) {
          // 1-byte values
          case GlobalMetadataIdentifier.sportsLeagueId:
          case GlobalMetadataIdentifier.trafficWeatherCityId:
            parsedValue = gmTagValue[index];
            index += 1;
            break;

          // 2-byte values (big-endian)
          case GlobalMetadataIdentifier.channelMetadataTableVersion:
          case GlobalMetadataIdentifier.channelMetadataRecordCount:
          case GlobalMetadataIdentifier.trafficWeatherCityTableVersion:
          case GlobalMetadataIdentifier.trafficWeatherCityRecordCount:
          case GlobalMetadataIdentifier.sportsTeamTableVersion:
          case GlobalMetadataIdentifier.sportsTeamRecordCount:
          case GlobalMetadataIdentifier.sportsLeagueTableVersion:
          case GlobalMetadataIdentifier.sportsLeagueRecordCount:
          case GlobalMetadataIdentifier.sportsTeamId:
            if (index + 1 < gmTagValue.length) {
              parsedValue = (gmTagValue[index] << 8) | gmTagValue[index + 1];
              index += 2;
            } else {
              if (logMetadata) {
                logger.t(
                    'GMI Parser: Not enough bytes for 2-byte value (need 2)');
              }
            }
            break;

          // Strings (null-terminated)
          case GlobalMetadataIdentifier.itunesSxmUrl:
          case GlobalMetadataIdentifier.trafficWeatherCityAbbreviation:
          case GlobalMetadataIdentifier.trafficWeatherCityName:
          case GlobalMetadataIdentifier.sportsTeamAbbreviation:
          case GlobalMetadataIdentifier.sportsTeamName:
          case GlobalMetadataIdentifier.sportsTeamNickname:
          case GlobalMetadataIdentifier.sportsLeagueShortName:
          case GlobalMetadataIdentifier.sportsLeagueLongName:
          case GlobalMetadataIdentifier.sportsLeagueType:
            if (index < gmTagValue.length) {
              List<int> stringBytes = [];
              while (index < gmTagValue.length && gmTagValue[index] != 0) {
                stringBytes.add(gmTagValue[index]);
                index++;
              }
              if (index < gmTagValue.length && gmTagValue[index] == 0) {
                index++; // Skip null terminator
              }
              parsedValue = decodeTextBytes(stringBytes);
              if (logMetadata) {
                logger.t('GMI Parser: Parsed string: "$parsedValue"');
              }
            }
            break;

          // Lists with 4-byte count followed by 1-byte entries
          case GlobalMetadataIdentifier.sportsTeamIdList:
          case GlobalMetadataIdentifier.sportsTeamTierList:
            if (index + 3 < gmTagValue.length) {
              int count = (gmTagValue[index] << 24) |
                  (gmTagValue[index + 1] << 16) |
                  (gmTagValue[index + 2] << 8) |
                  gmTagValue[index + 3];
              index += 4;
              if (logMetadata) {
                logger.t('GMI Parser: List count: $count');
              }

              List<int> entries = [];
              for (int i = 0; i < count; i++) {
                if (index >= gmTagValue.length) {
                  if (logMetadata) {
                    logger.t('GMI Parser: Ran out of bytes parsing list at $i');
                  }
                  break;
                }
                entries.add(gmTagValue[index]);
                index += 1;
              }
              parsedValue = entries;
            } else {
              if (logMetadata) {
                logger.t('GMI Parser: Not enough bytes for 4-byte list count');
              }
            }
            break;
        }

        if (parsedValue != null) {
          items.add(GlobalMetadataItem(identifier, parsedValue));
        }
      } catch (e) {
        // Stop parsing on unknown GMI tag
        if (logMetadata) {
          logger.t(
              'GMI Parser: Unknown 16-bit GMI tag: $gmiTag (0x${gmiTag.toRadixString(16).padLeft(4, '0').toUpperCase()}) - $e');
        }
        break;
      }
    }

    if (logMetadata) {
      logger.t(
          '--------------- GMI Parser: Completed, found ${items.length} items ---------------');
    }
    return items;
  }

  @override
  String toString() {
    String identifierName = identifier.toString().split('.').last;
    return 'GMI $identifierName: $value';
  }
}
