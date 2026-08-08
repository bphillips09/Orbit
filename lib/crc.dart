// CRC helpers
class CRC32 {
  static final List<int> crc32Table = _generateCrc32Table();

  static List<int> _generateCrc32Table() {
    const int polynomial = 0xEDB88320;
    List<int> table = List.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int j = 0; j < 8; j++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ polynomial;
        } else {
          crc >>= 1;
        }
      }
      table[i] = crc;
    }
    return table;
  }

  // Calculate CRC32 for a given buffer
  static int calculate(List<int> buffer) {
    int crc = 0xFFFFFFFF;
    for (int i = 0; i < buffer.length; i++) {
      crc = crc32Table[(buffer[i] ^ crc) & 0xFF] ^ (crc >> 8);
    }
    return ~crc & 0xFFFFFFFF;
  }

  // Check the CRC32 of the given buffer
  static bool check(List<int> buffer, int crc) {
    int calculatedCrc = calculate(buffer);
    return calculatedCrc == crc;
  }
}

// CRC-16/XMODEM-style
class CRC16 {
  static int calculate(List<int> buffer) {
    int crc = 0xFFFF;
    for (final int byte in buffer) {
      crc ^= ((byte & 0xFF) << 8);
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return (~crc) & 0xFFFF;
  }

  static bool check(List<int> buffer, int crc) {
    return calculate(buffer) == crc;
  }
}
