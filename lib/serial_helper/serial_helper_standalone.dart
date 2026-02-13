// Serial Helper for Standalone Platforms
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:orbit/logging.dart';

class StandaloneSerialHelper implements SerialHelper {
  late SerialPort _serialPort;
  late SerialPortReader _reader;

  UsbDevice? _androidDevice;
  UsbPort? _androidPort;
  bool _requestedAndroidUsbPermission = false;

  bool expectedClosure = false;
  bool _desktopOpen = false;

  Socket? _socket;
  StreamSubscription<List<int>>? _socketSubscription;
  bool _usingNetwork = false;
  String _networkHost = '';
  int _networkUartPort = 0;
  int? _networkGpioPort;
  Socket? _gpioSocket;
  StreamSubscription<List<int>>? _gpioSubscription;
  final List<int> _gpioRxBuffer = <int>[];
  Completer<Uint8List?>? _gpioReadCompleter;
  int _gpioReadNeeded = 0;
  Timer? _gpioReadTimer;
  final List<int> _uartRxBuffer = <int>[];
  Completer<Uint8List?>? _uartReadCompleter;
  int _uartReadNeeded = 0;
  Timer? _uartReadTimer;
  int _uartSeq = 1;
  Function(Uint8List)? _clientOnData;
  Function(Object, bool)? _clientOnEnd;
  bool _recvPolling = false;
  Completer<void>? _writeMutex;
  Completer<void>? _ioMutex;

  @override
  Future<List<Object>> listPorts() async {
    if (Platform.isAndroid) {
      var devices = await UsbSerial.listDevices();
      return devices.map((dev) => dev.productName ?? dev.deviceName).toList();
    } else {
      return SerialPort.availablePorts;
    }
  }

  @override
  Future<bool> openPort(
    Object? port,
    int baud, {
    SerialTransport transport = SerialTransport.serial,
  }) async {
    final String portString = (port ?? '').toString().trim();

    if (transport == SerialTransport.network) {
      if (portString.isEmpty) {
        logger.w('Empty UART-over-IP endpoint');
        return false;
      }
      logger.d('Opening UART-over-IP endpoint: $portString');
      try {
        final parts = portString.split(':');
        if (parts.length < 2 || parts[0].trim().isEmpty) {
          logger.w('Invalid UART-over-IP spec "$portString"');
          return false;
        }
        _networkHost = parts[0].trim();
        _networkUartPort = int.tryParse(parts[1].trim()) ?? 0;
        _networkGpioPort =
            parts.length >= 3 ? int.tryParse(parts[2].trim()) : null;
        if (_networkUartPort <= 0 || _networkUartPort > 65535) {
          logger.w('Invalid network port in "$portString"');
          return false;
        }

        logger.i('Connecting to UART-over-IP');
        // Connect UART-over-IP
        _socket = await Socket.connect(
          _networkHost,
          _networkUartPort,
          timeout: const Duration(seconds: 5),
        );
        logger.i('Connected to $_networkHost:$_networkUartPort');
        _usingNetwork = true;
        expectedClosure = false;
        // Attach buffered subscription for exact reads
        _attachUartSubscription();
        logger.i('Attached buffered subscription for exact reads');
        // Send CONFIG to set UART 1 parameters and baud (framed)
        final bool cfgOk = await _uartSendConfig(baud);
        logger.i('UARTIP CONFIG sent: $cfgOk');
        if (!cfgOk) {
          throw 'UARTIP CONFIG failed';
        }
        // Establish GPIO connection and perform reset/power-cycle after UART CONFIG
        try {
          if (_networkGpioPort != null &&
              _networkGpioPort! > 0 &&
              _networkGpioPort! <= 65535) {
            await _connectGpio();
            logger.i('GPIO-over-IP connected');
            await _initializeGpioSequence();
          }
        } catch (e) {
          logger.w('GPIO-over-IP init/reset failed (non-fatal): $e');
        }
        logger.i('Connected to $_networkHost:$_networkUartPort');
        // Start background RECV polling to pull device data
        _startRecvPolling();
        return true;
      } catch (e) {
        logger.e('Failed to connect to UART-over-IP endpoint: $e');
        try {
          await _socket?.close();
        } catch (_) {}
        _socket = null;
        _usingNetwork = false;
        return false;
      }
    }

    if (Platform.isAndroid) {
      logger.d('Opening port (${port ?? "none"}) on Mobile');

      var selectedDevice = (port ?? '').toString();
      var allDevices = await UsbSerial.listDevices();

      for (var dev in allDevices) {
        if (dev.productName == selectedDevice ||
            dev.deviceName == selectedDevice) {
          _androidDevice = dev;
          break;
        }
      }

      if (_androidDevice == null) {
        logger.d('No Android Device');
        return false;
      }

      _androidPort = await _androidDevice!.create();

      bool openResult = await _androidPort!.open();
      if (!openResult) {
        logger.d('Cannot open the device');
        return false;
      }

      _androidPort!.setPortParameters(
          baud, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    } else {
      logger.d('Opening port (${port ?? "none"}) on Desktop');

      _serialPort = SerialPort((port ?? '').toString());

      if (_serialPort.isOpen) {
        return true;
      }

      if (!_serialPort.openReadWrite()) {
        return false;
      }

      var config = _serialPort.config;
      config
        ..baudRate = baud
        ..bits = 8
        ..parity = SerialPortParity.none
        ..stopBits = 1
        ..xonXoff = 0
        ..rts = 0
        ..dtr = 0;

      _serialPort.config = config;
      config.dispose();
      _desktopOpen = true;
    }

    expectedClosure = false;

    return true;
  }

  @override
  Future<bool> ensureSerialPermission() async {
    if (!Platform.isAndroid) return true;
    if (_requestedAndroidUsbPermission) return true;
    final devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      return true;
    }
    try {
      final tempPort = await devices.first.create();
      try {
        await tempPort?.close();
      } catch (_) {}
      _requestedAndroidUsbPermission = true;
      return true;
    } catch (_) {
      // user may deny
      _requestedAndroidUsbPermission = true;
      return false;
    }
  }

  @override
  Future<int> writeData(Uint8List data) async {
    if (_usingNetwork) {
      if (_socket == null) {
        logger.d('Network socket not available');
        return -1;
      }
      // Send in chunks up to 1024 bytes
      int offset = 0;
      const int kChunk = 1024;
      while (offset < data.length) {
        final end =
            (offset + kChunk) > data.length ? data.length : (offset + kChunk);
        final slice = Uint8List.sublistView(data, offset, end);
        final ok = await _uartSendFramed(slice);
        if (!ok) return -1;
        offset = end;
      }
      return 0;
    } else if (Platform.isAndroid) {
      if (_androidPort == null) {
        logger.d('Android port not available');
        return -1;
      }
      await _androidPort!.write(data);
      return 0;
    } else {
      if (!_serialPort.isOpen) {
        logger.d('Serial port not open');
        return -1;
      }
      return _serialPort.write(data);
    }
  }

  @override
  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) async {
    if (_usingNetwork) {
      if (_socket == null) {
        logger.d('Network socket not available');
        return;
      }
      // Register client callbacks
      _clientOnData = (bytes) {
        onData(bytes);
      };
      _clientOnEnd = onEnd;
      return;
    } else if (Platform.isAndroid) {
      if (_androidPort == null) {
        logger.d('Android port not available');
        return;
      }

      try {
        _androidPort!.inputStream?.listen(onData);
      } catch (e) {
        logger.d("Port Error: $e");
        onEnd('Port Error: $e', false);
      }
    } else {
      if (!_serialPort.isOpen) {
        return;
      }

      _reader = SerialPortReader(_serialPort);

      try {
        _reader.stream.listen(
          onData,
          onError: (err) {
            onEnd(err, expectedClosure);
          },
          onDone: () {
            onEnd('Done', true);
          },
          cancelOnError: true,
        );
      } catch (e) {
        logger.d("Port Error: $e");
        onEnd('Port Error: $e', false);
      }
    }
  }

  Future<bool> configureNetworkUartBaud(int baud) async {
    try {
      return await _uartSendConfig(baud);
    } catch (_) {
      return false;
    }
  }

  Future<void> _connectGpio() async {
    try {
      _gpioSocket = await Socket.connect(
        _networkHost,
        _networkGpioPort!,
        timeout: const Duration(seconds: 3),
      );
      logger.i('Connected to GPIOIP $_networkHost:$_networkGpioPort');
      // Attach a single subscription to buffer incoming bytes
      _gpioSubscription?.cancel().catchError((_) {});
      _gpioSubscription = _gpioSocket!.listen((chunk) {
        if (chunk.isEmpty) return;
        _gpioRxBuffer.addAll(chunk);
        _completeGpioReadIfReady();
      }, onError: (e) {
        _finishGpioRead(null);
      }, onDone: () {
        _finishGpioRead(null);
      }, cancelOnError: true);
    } catch (e) {
      _gpioSocket = null;
      rethrow;
    }
  }

  Future<bool> _gpioSendLevel(
      {required int gpioIndex, required int level}) async {
    final s = _gpioSocket;
    if (s == null) return false;
    try {
      final header = Uint8List.fromList([0x01, 0x11, 0x80, 0x01]);
      final wireLevel = (level == 0) ? 1 : 0;
      final payload = Uint8List.fromList([gpioIndex & 0xFF, wireLevel & 0xFF]);
      s.add(header);
      s.add(payload);
      await s.flush();

      // Expect 6-byte ACK (4-byte header + 2-byte echo [gpio, level])
      final ack = await _gpioReadExact(6, const Duration(milliseconds: 250));
      if (ack == null || ack.length != 6) {
        throw 'ACK timeout';
      }
      final version = ack[0] | (ack[1] << 8);
      if (version != 0x1101) {
        throw 'ACK version mismatch: 0x${version.toRadixString(16)}';
      }
      final opLo = ack[2];
      final opHi = ack[3] & 0x7F;
      final opA = opLo | (opHi << 8);
      final opB = opHi | (opLo << 8);
      final opOk = (opA == 0x0001) || (opA == 0x0100) || (opB == 0x0001);
      if (!opOk) {
        throw 'ACK op unexpected: $opA';
      }
      final ackGpio = ack[4] & 0xFF;
      final ackLevel = ack[5] & 0xFF;
      if (ackGpio != (gpioIndex & 0xFF) || ackLevel != wireLevel) {
        throw 'ACK content mismatch (gpio=$ackGpio level=$ackLevel)';
      }
      return true;
    } catch (e) {
      logger.w('GPIO send failed: $e');
      // Keep socket if we received any response, otherwise drop on I/O errors
      if (e is SocketException || e.toString().contains('timeout')) {
        try {
          await _gpioSocket?.close();
        } catch (_) {}
        _gpioSocket = null;
        try {
          await _gpioSubscription?.cancel();
        } catch (_) {}
        _gpioSubscription = null;
        _gpioRxBuffer.clear();
        _finishGpioRead(null);
      }
      return false;
    }
  }

  void _completeGpioReadIfReady() {
    if (_gpioReadCompleter == null) return;
    if (_gpioRxBuffer.length < _gpioReadNeeded) return;
    final bytes = Uint8List.fromList(_gpioRxBuffer.sublist(0, _gpioReadNeeded));
    _gpioRxBuffer.removeRange(0, _gpioReadNeeded);
    _finishGpioRead(bytes);
  }

  void _finishGpioRead(Uint8List? data) {
    _gpioReadTimer?.cancel();
    _gpioReadTimer = null;
    final c = _gpioReadCompleter;
    _gpioReadCompleter = null;
    _gpioReadNeeded = 0;
    if (c != null && !c.isCompleted) {
      c.complete(data);
    }
  }

  Future<Uint8List?> _gpioReadExact(int length, Duration timeout) async {
    if (length <= 0) return Uint8List(0);
    if (_gpioReadCompleter != null) {
      // Re-entrant call, treat as failure
      return null;
    }
    _gpioReadNeeded = length;
    final completer = Completer<Uint8List?>();
    _gpioReadCompleter = completer;
    _gpioReadTimer = Timer(timeout, () => _finishGpioRead(null));
    _completeGpioReadIfReady();
    final res = await completer.future;
    return res;
  }

  void _attachUartSubscription() {
    try {
      _socketSubscription?.cancel().catchError((_) {});
    } catch (_) {}
    _socketSubscription = _socket?.listen((chunk) {
      if (chunk.isEmpty) return;
      _uartRxBuffer.addAll(chunk);
      _completeUartReadIfReady();
    }, onError: (e) {
      logger.w('UART READ error: $e');
      _finishUartRead(null);
      try {
        _clientOnEnd?.call(e, expectedClosure);
      } catch (_) {}
    }, onDone: () {
      logger.w('UARTIP READ done (socket closed by peer)');
      _finishUartRead(null);
      try {
        _clientOnEnd?.call('Socket closed', true);
      } catch (_) {}
    }, cancelOnError: true);
  }

  Future<Uint8List?> _uartReadExact(int length, Duration timeout) async {
    if (length <= 0) return Uint8List(0);
    if (_uartReadCompleter != null) {
      logger.w('UARTIP READ exact re-entrant call');
      return null;
    }
    _uartReadNeeded = length;
    final completer = Completer<Uint8List?>();
    _uartReadCompleter = completer;
    _uartReadTimer = Timer(timeout, () => _finishUartRead(null));
    _completeUartReadIfReady();
    final res = await completer.future;
    return res;
  }

  void _completeUartReadIfReady() {
    if (_uartReadCompleter == null) return;
    if (_uartRxBuffer.length < _uartReadNeeded) return;
    final bytes = Uint8List.fromList(_uartRxBuffer.sublist(0, _uartReadNeeded));
    _uartRxBuffer.removeRange(0, _uartReadNeeded);
    _finishUartRead(bytes);
  }

  void _finishUartRead(Uint8List? data) {
    _uartReadTimer?.cancel();
    _uartReadTimer = null;
    final c = _uartReadCompleter;
    _uartReadCompleter = null;
    _uartReadNeeded = 0;
    if (c != null && !c.isCompleted) {
      c.complete(data);
    }
  }

  Uint8List _uartHeader12({required int op, required int param}) {
    final b = BytesBuilder();
    b.add([0x01, 0x11]);
    b.add([0x80, op & 0xFF]);
    final seq = (_uartSeq++ & 0x7FFFFFFF);
    b.add(_u32be(seq));
    b.add(_u32be(param));
    return Uint8List.fromList(b.toBytes());
  }

  bool _checkReplyHeader12(Uint8List hdr, int expectedOp) {
    if (hdr.length < 12) return false;
    if (!(hdr[0] == 0x01 && hdr[1] == 0x11)) return false;
    final op = hdr[3] & 0x7F;
    final alt = hdr[2] & 0x7F;
    return (op == expectedOp) || (alt == expectedOp);
  }

  Future<bool> _uartSendConfig(int baud) async {
    final s = _socket;
    if (s == null) return false;
    return _withIoLock<bool>(() async {
      try {
        final header = _uartHeader12(op: 0x01, param: 0);
        final payload = BytesBuilder();
        payload.add([0x01, 0x04]);
        payload.add(_u32be(baud));
        payload.add([0x00]);
        await _socketWrite(header);
        await _socketWrite(payload.toBytes());
        logger.i('UARTIP CONFIG sent: ${payload.toBytes()}');
        logger.i('UARTIP CONFIG flushed');
        // Read 12-byte reply header
        final ack = await _uartReadExact(12, const Duration(seconds: 2));
        logger.i('UARTIP CONFIG ack: $ack');
        if (ack == null || ack.length < 12) return false;
        if (!_checkReplyHeader12(ack, 0x01)) return false;
        // Status must be zero
        final status = _u32beRead(ack, 8);
        if (status != 0) return false;
        logger.i('UARTIP CONFIG ack OK');
        return true;
      } catch (e) {
        logger.w('UARTIP CONFIG failed: $e');
        return false;
      }
    });
  }

  Future<bool> _uartSendFramed(Uint8List data) async {
    final s = _socket;
    if (s == null) return false;
    return _withIoLock<bool>(() async {
      try {
        final header = _uartHeader12(op: 0x02, param: 0);
        final length = data.length & 0xFFFF;
        final sub =
            Uint8List.fromList([0x01, (length >> 8) & 0xFF, length & 0xFF]);
        await _socketWrite(header);
        await _socketWrite(sub);
        await _socketWrite(data);
        // Read SEND reply to keep stream aligned
        final ack = await _uartReadExact(12, const Duration(seconds: 2));
        if (ack == null || ack.length < 12) return false;
        if (!_checkReplyHeader12(ack, 0x02)) return false;
        final status = _u32beRead(ack, 8);
        if (status != 0) return false;
        return true;
      } catch (e) {
        logger.e('UARTIP SEND failed: $e');
        return false;
      }
    });
  }

  // Ensure only one writer is pushing to the socket at a time
  Future<void> _socketWrite(List<int> bytes) async {
    final prior = _writeMutex;
    final current = Completer<void>();
    _writeMutex = current;
    try {
      if (prior != null) {
        await prior.future;
      }
      final sock = _socket;
      if (sock == null) {
        throw StateError('UARTIP socket is closed');
      }
      sock.add(bytes);
    } finally {
      if (!current.isCompleted) current.complete();
      // Only clear if this completer is still the head of the chain
      if (identical(_writeMutex, current)) {
        _writeMutex = null;
      }
    }
  }

  // Ensure framed IO transactions do not interleave
  Future<T> _withIoLock<T>(Future<T> Function() action) async {
    final prior = _ioMutex;
    final current = Completer<void>();
    _ioMutex = current;
    try {
      if (prior != null) {
        await prior.future;
      }
      return await action();
    } finally {
      if (!current.isCompleted) current.complete();
      if (identical(_ioMutex, current)) {
        _ioMutex = null;
      }
    }
  }

  void _startRecvPolling() {
    if (_recvPolling) return;
    _recvPolling = true;
    () async {
      while (_usingNetwork && _socket != null && _recvPolling) {
        // Request 1024 bytes per RECV
        final ok =
            await _uartRecvOnce(1024, const Duration(milliseconds: 1000));
        if (!ok) {
          // Backoff to avoid tight loop on timeout
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }
      _recvPolling = false;
    }();
  }

  Future<bool> _uartRecvOnce(int maxBytes, Duration timeout) async {
    final s = _socket;
    if (s == null) return false;
    return _withIoLock<bool>(() async {
      try {
        final header = _uartHeader12(op: 0x03, param: 0);
        final want = maxBytes & 0xFFFF;
        final sub = Uint8List.fromList([0x01, (want >> 8) & 0xFF, want & 0xFF]);
        await _socketWrite(header);
        await _socketWrite(sub);
        // Read 12-byte reply header
        final ack = await _uartReadExact(12, timeout);
        if (ack == null || ack.length < 12) return false;
        if (!_checkReplyHeader12(ack, 0x03)) return false;
        // If status is non-zero, stop
        final status = _u32beRead(ack, 8);
        if (status != 0) {
          return true;
        }
        // Read subheader (uart+len)
        final subhdr = await _uartReadExact(3, timeout);
        if (subhdr == null || subhdr.length != 3) return false;
        final len = ((subhdr[1] & 0xFF) << 8) | (subhdr[2] & 0xFF);
        if (len > 0) {
          final data = await _uartReadExact(len, timeout);
          if (data == null || data.length != len) return false;
          try {
            _clientOnData?.call(data);
          } catch (_) {}
        }
        return true;
      } catch (e) {
        return false;
      }
    });
  }

  List<int> _u32be(int value) => [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  int _u32beRead(Uint8List bytes, int offset) {
    return ((bytes[offset] & 0xFF) << 24) |
        ((bytes[offset + 1] & 0xFF) << 16) |
        ((bytes[offset + 2] & 0xFF) << 8) |
        (bytes[offset + 3] & 0xFF);
  }

  Future<void> _initializeGpioSequence() async {
    // If GPIO socket is not viable, skip sequence
    if (_gpioSocket == null) {
      logger.w('GPIO socket not available, skipping reset/power-cycle');
      return;
    }
    bool ok = true;
    ok = (await _gpioSendLevel(gpioIndex: 4, level: 1)) && ok;
    if (_gpioSocket == null) ok = false;
    ok = (await _gpioSendLevel(gpioIndex: 5, level: 1)) && ok;
    if (_gpioSocket == null) ok = false;
    await Future.delayed(const Duration(milliseconds: 250));
    if (_gpioSocket != null) {
      ok = (await _gpioSendLevel(gpioIndex: 5, level: 0)) && ok;
    } else {
      ok = false;
    }
    if (_gpioSocket != null) {
      ok = (await _gpioSendLevel(gpioIndex: 4, level: 0)) && ok;
    } else {
      ok = false;
    }
    if (ok) {
      logger.d('GPIO reset/power-cycle sequence complete');
    } else {
      logger.w('GPIO reset/power-cycle sequence had errors');
    }
  }

  @override
  Future<bool> closePort() async {
    if (_usingNetwork) {
      logger.d('Closing UART-over-IP socket');
      try {
        expectedClosure = true;
        try {
          await _socketSubscription?.cancel();
        } catch (e) {
          logger.w('Error canceling socket subscription: $e');
        }
        try {
          await _socket?.flush();
        } catch (e) {
          logger.w('Error flushing socket: $e');
        }
        try {
          await _socket?.close();
        } catch (e) {
          logger.w('Error closing socket: $e');
        }
        try {
          await _gpioSocket?.close();
        } catch (e) {
          logger.w('Error closing GPIO socket: $e');
        }
        try {
          await _gpioSubscription?.cancel();
        } catch (e) {
          logger.w('Error canceling GPIO subscription: $e');
        }
        _gpioSubscription = null;
        _gpioRxBuffer.clear();
        _finishGpioRead(null);
      } catch (e) {
        logger.w('Error closing network socket: $e');
      } finally {
        _socketSubscription = null;
        _socket = null;
        _usingNetwork = false;
        _gpioSocket = null;
      }
      return true;
    } else if (Platform.isAndroid) {
      logger.d('Closing port on Mobile');
      if (_androidPort == null) {
        logger.d('Android port not available');
        return false;
      }

      return await _androidPort!.close();
    } else {
      logger.d('Closing port on Desktop');
      if (!_desktopOpen) {
        return true;
      }
      if (!_serialPort.isOpen) {
        logger.d('Serial port not open');
        _desktopOpen = false;
        return true;
      }
      int timeout = 5;
      while (_serialPort.isOpen && timeout > 0) {
        expectedClosure = true;
        _serialPort.close();
        await Future.delayed(const Duration(seconds: 1));
        timeout--;
      }
      _desktopOpen = false;
      return _serialPort.close();
    }
  }

  @override
  Future<String> getPortName(Object port) async {
    if (Platform.isAndroid) {
      var devices = await UsbSerial.listDevices();
      for (var device in devices) {
        if (device == port) {
          return device.productName ?? device.deviceName;
        }
      }

      return '';
    } else {
      return port.toString();
    }
  }
}

SerialHelper getSerialHelper() => StandaloneSerialHelper();
