class BitBuffer {
  final List<int> buffer;
  int _position = 0; // Pointer to the current byte in the buffer
  int _validBits = 0; // Remaining valid bits in the seed
  int _seed = 0; // Stores buffered bits
  bool _error = false; // Error flag
  // Callback invoked when more data is needed. Should return 0
  // on success and non-zero on failure; on failure `_error` is set
  Function? replenish; // Callback for replenishing the buffer

  BitBuffer(this.buffer, {this.replenish});

  // Aligns to the next byte boundary by discarding excess bits in `_seed`
  void align() {
    int remainingBits = _validBits % 8;
    if (remainingBits > 0) {
      _validBits -= remainingBits;
      _seed &= (1 << _validBits) - 1;
    }
  }

  // Ensures at least [len] bits are buffered in `_seed`
  void _ensureBits(int len) {
    while (_validBits < len) {
      if (_position < buffer.length) {
        _seed = (_seed << 8) | buffer[_position++];
        _validBits += 8;
      } else if (replenish != null) {
        if (replenish!() != 0) {
          _error = true;
          break;
        }
      } else {
        _error = true;
        break;
      }
    }
  }

  // Reads [len] bits from the buffer and advances the internal cursor
  int readBits(int len) {
    if (_error) return 0;

    _ensureBits(len);

    if (_error) return 0;

    int shift = _validBits - len;
    int result = (_seed >> shift) & ((1 << len) - 1);
    _validBits -= len;
    _seed &= ((1 << _validBits) - 1);

    return result;
  }

  List<int> readBytes(int byteCount) {
    List<int> bytes = [];
    for (int i = 0; i < byteCount; i++) {
      bytes.add(readBits(8));
    }
    return bytes;
  }

  void skipBits(int len) {
    if (_error) return;

    _ensureBits(len);

    if (_error) return;

    _validBits -= len;
    _seed &= ((1 << _validBits) - 1);
  }

  // Returns the current byte position within [buffer]
  int get position => _position;

  // Returns the number of remaining bytes in the buffer
  int get remainingBytes => buffer.length - _position;

  // Returns remaining bytes and advances position to the end
  List<int> get remainingData {
    if (_position >= buffer.length) return [];
    List<int> data = buffer.sublist(_position);
    _position = buffer.length; // Advance position to the end of the buffer
    return data;
  }

  List<int> get viewRemainingData {
    if (_position >= buffer.length) return [];
    List<int> data = buffer.sublist(_position);
    return data;
  }

  // True if an error occurred during reading or replenishment
  bool get hasError => _error;

  // Reads all remaining bits from the current bit position and returns them
  // as a newly packed byte list (zero-padded if necessary)
  List<int> readRemainingBitsAsBytes() {
    if (_error) return [];
    // Compute total remaining bits: currently buffered bits + full bytes left
    int totalBits = _validBits + (buffer.length - _position) * 8;
    if (totalBits <= 0) {
      // Consume remaining bytes like remainingData for consistency
      _position = buffer.length;
      _validBits = 0;
      _seed = 0;
      return <int>[];
    }
    final List<int> out = <int>[];
    while (totalBits >= 8) {
      out.add(readBits(8));
      if (_error) return out;
      totalBits -= 8;
    }
    if (totalBits > 0) {
      // Read the remaining high-order bits and pad the low bits with zeros
      final int rem = readBits(totalBits);
      if (!_error) {
        final int padded = (rem & ((1 << totalBits) - 1)) << (8 - totalBits);
        out.add(padded & 0xFF);
      }
    }
    return out;
  }

  // Peek bits without advancing the internal cursor
  int peekBits(int len) {
    if (_error) return 0;
    final int savedPos = _position;
    final int savedValid = _validBits;
    final int savedSeed = _seed;
    final bool savedErr = _error;
    final int result = readBits(len);
    _position = savedPos;
    _validBits = savedValid;
    _seed = savedSeed;
    _error = savedErr;
    return result;
  }

  int get debugBytePos => _position;
  int get debugValidBits => _validBits;
}
