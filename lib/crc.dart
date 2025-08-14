// CRC32, calculates the CRC32 of a given buffer
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
