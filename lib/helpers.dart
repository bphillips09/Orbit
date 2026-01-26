// Helpers, utility functions
import 'dart:typed_data';

import 'package:flutter/material.dart';

// Detect landscape orientation
bool isLandscape(BuildContext context) {
  final size = MediaQuery.of(context).size;
  return size.width > size.height / 1.1;
}

// Standardized signal icon
IconData getSignalIcon(int signalQuality, {bool isAntennaConnected = true}) {
  if (!isAntennaConnected) {
    return Icons.signal_cellular_connected_no_internet_0_bar;
  }

  switch (signalQuality) {
    case 0:
      return Icons.signal_cellular_connected_no_internet_0_bar;
    case 1:
      return Icons.signal_cellular_alt_1_bar;
    case 2:
    case 3:
      return Icons.signal_cellular_alt_2_bar;
    case 4:
      return Icons.signal_cellular_alt;
    default:
      return Icons.signal_cellular_connected_no_internet_0_bar;
  }
}

// Get the icon for a given category name
IconData getCategoryIcon(String categoryName) {
  final String name = categoryName.toLowerCase();

  if (name.contains('sport') || name.contains('pxp')) {
    if (name.contains('nfl')) {
      return Icons.sports_football;
    }
    if (name.contains('nba')) {
      return Icons.sports_basketball;
    }
    if (name.contains('mlb')) {
      return Icons.sports_baseball;
    }
    if (name.contains('nhl')) {
      return Icons.sports_hockey;
    }
    if (name.contains('ncaa')) {
      return Icons.sports_soccer;
    }
    if (name.contains('cfl')) {
      return Icons.sports_football;
    }

    return Icons.sports_basketball;
  }

  if (name.contains('talk') ||
      name.contains('stern') ||
      name.contains('entertainment')) {
    return Icons.mic;
  }

  if (name.contains('news')) {
    return Icons.gavel;
  }

  if (name.contains('religion')) {
    return Icons.church;
  }

  if (name.contains('more')) {
    return Icons.library_music;
  }

  if (name.contains('canadian')) {
    return Icons.flag;
  }

  if (name.contains('free')) {
    return Icons.money_off;
  }

  if (name.contains('comedy')) {
    return Icons.emoji_emotions;
  }

  if (name.contains('traffic') || name.contains('weather')) {
    return Icons.traffic;
  }

  if (name.contains('kid') || name.contains('family')) {
    return Icons.child_friendly;
  }

  return Icons.music_note;
}

// Combine two bytes into a 16-bit value
int bitCombine(int msb, int lsb) {
  return (msb << 8) | (lsb & 0xff);
}

// Split a 16-bit value into two bytes
(int msb, int lsb) bitSplit(int value) {
  return ((value >> 8) & 0xFF, value & 0xFF);
}

// Convert a signed byte to an unsigned byte
int signedToUnsigned(int signedByte) {
  return signedByte & 0xFF;
}

// Convert an unsigned integer to a signed integer
int unsignedToSignedInt(int v, int bits) {
  final int mask = (1 << bits) - 1;
  v &= mask;
  final int signBit = 1 << (bits - 1);
  return (v ^ signBit) - signBit;
}

// Convert a list of bytes to a 32-bit integer
int bytesToInt32(List<int> bytes) {
  if (bytes.length != 4) {
    return -1;
  }

  return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
}

// Truncate a string
String truncate(String s, {int max = 2000}) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}… (truncated)';
}

// Convert a list of bytes to a hex string
String bytesToHex(List<int> bytes, {bool upperCase = true}) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(((b & 0xFF).toRadixString(16)).padLeft(2, '0'));
  }
  final s = sb.toString();
  return upperCase ? s.toUpperCase() : s;
}

// Convert a hex string to a list of bytes
List<int> hexStringToBytes(String hex) {
  String cleaned = hex.trim();
  if (cleaned.length % 2 == 1) cleaned = '0$cleaned';
  final out = Uint8List(cleaned.length ~/ 2);
  for (int i = 0; i < cleaned.length; i += 2) {
    out[i >> 1] = int.parse(cleaned.substring(i, i + 2), radix: 16);
  }
  return out;
}

// Process a DMI byte list into big-endian 16-bit values
// Expects [dmi] to contain at least `dmiCount * 2` bytes, where each pair
// `(MSB, LSB)` is combined to a 16-bit integer
List<int> processDMI(List<int> dmi, int dmiCount) {
  List<int> result = [];

  for (int i = 0; i < dmiCount; i++) {
    int index = i * 2;
    if (index + 1 >= dmi.length) break;
    int value = (dmi[index] << 8) | dmi[index + 1];
    result.add(value);
  }

  return result;
}
