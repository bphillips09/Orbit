// Serial Helper for Standalone UART-over-IP
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:orbit/logging.dart';

class StandaloneUartIpHelper {
  static const bool enableFastReconnectTuning = true;
  static const Duration baseReconnectBackoff = Duration(milliseconds: 250);
  static const Duration maxReconnectBackoff = Duration(seconds: 5);
  static const Duration fastAckTimeout = Duration(milliseconds: 750);
  static const Duration slowAckTimeout = Duration(seconds: 2);
  static const Duration slowRecvTimeout = Duration(milliseconds: 1000);

  Socket? _socket;
  StreamSubscription<List<int>>? _socketSubscription;
  bool _usingNetwork = false;
  String _networkHost = '';
  int _networkUartPort = 0;
  int? _networkGpioPort;
  int _networkBaud = 57600;
  DateTime? _lastNetworkReconnectAttempt;
  int _networkReconnectFailures = 0;
  DateTime? _disconnectDetectedAt;
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
  bool _proactiveReconnectLoopActive = false;
  int _consecutiveRecvFailures = 0;
  Completer<void>? _writeMutex;
  Completer<void>? _ioMutex;
  bool expectedClosure = false;

  bool get isConnected => _usingNetwork && _socket != null;

  Future<bool> openPort(Object? port, int baud) async {
    final portString = (port ?? '').toString().trim();
    if (portString.isEmpty) return false;

    try {
      final parts = portString.split(':');
      if (parts.length < 2 || parts[0].trim().isEmpty) return false;
      _networkHost = parts[0].trim();
      _networkUartPort = int.tryParse(parts[1].trim()) ?? 0;
      _networkGpioPort =
          parts.length >= 3 ? int.tryParse(parts[2].trim()) : null;
      _networkBaud = baud;
      if (_networkUartPort <= 0 || _networkUartPort > 65535) return false;

      _socket = await Socket.connect(
        _networkHost,
        _networkUartPort,
        timeout: const Duration(seconds: 5),
      );
      _usingNetwork = true;
      expectedClosure = false;
      _attachUartSubscription();

      final cfgOk = await _uartSendConfig(baud);
      if (!cfgOk) throw 'UARTIP CONFIG failed';

      try {
        if (_networkGpioPort != null &&
            _networkGpioPort! > 0 &&
            _networkGpioPort! <= 65535) {
          await _connectGpio();
          await _initializeGpioSequence();
        }
      } catch (e) {
        logger.w('GPIO-over-IP init/reset failed (non-fatal): $e');
      }

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

  Future<bool> reconfigureBaud(int baud) async {
    _networkBaud = baud;
    try {
      return await _uartSendConfig(baud);
    } catch (_) {
      return false;
    }
  }

  Future<int> writeData(Uint8List data) async {
    if (_socket == null) {
      final ok = await _maybeReconnectNetwork();
      if (!ok || _socket == null) return -1;
    }
    var offset = 0;
    const chunk = 1024;
    while (offset < data.length) {
      final end =
          (offset + chunk) > data.length ? data.length : (offset + chunk);
      final slice = Uint8List.sublistView(data, offset, end);
      final ok = await _uartSendFramed(slice);
      if (!ok) return -1;
      offset = end;
    }
    return 0;
  }

  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) async {
    if (_socket == null) {
      await _maybeReconnectNetwork();
      if (_socket == null) return;
    }
    _clientOnData = onData;
    _clientOnEnd = onEnd;
  }

  Future<bool> closePort() async {
    if (!_usingNetwork) return true;
    try {
      expectedClosure = true;
      try {
        await _socketSubscription?.cancel();
      } catch (_) {}
      try {
        await _socket?.flush();
      } catch (_) {}
      try {
        await _socket?.close();
      } catch (_) {}
      try {
        await _gpioSocket?.close();
      } catch (_) {}
      try {
        await _gpioSubscription?.cancel();
      } catch (_) {}
      _gpioSubscription = null;
      _gpioRxBuffer.clear();
      _finishGpioRead(null);
    } finally {
      _socketSubscription = null;
      _socket = null;
      _gpioSocket = null;
      _disconnectDetectedAt = null;
      _networkReconnectFailures = 0;
      _recvPolling = false;
    }
    return true;
  }

  Future<void> _connectGpio() async {
    try {
      _gpioSocket = await Socket.connect(
        _networkHost,
        _networkGpioPort!,
        timeout: const Duration(seconds: 3),
      );
      _gpioSubscription?.cancel().catchError((_) {});
      _gpioSubscription = _gpioSocket!.listen((chunk) {
        if (chunk.isEmpty) return;
        _gpioRxBuffer.addAll(chunk);
        _completeGpioReadIfReady();
      }, onError: (_) {
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
      final ack = await _gpioReadExact(6, const Duration(milliseconds: 250));
      if (ack == null || ack.length != 6) throw 'ACK timeout';
      return true;
    } catch (_) {
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
    if (c != null && !c.isCompleted) c.complete(data);
  }

  Future<Uint8List?> _gpioReadExact(int length, Duration timeout) async {
    if (length <= 0) return Uint8List(0);
    if (_gpioReadCompleter != null) return null;
    _gpioReadNeeded = length;
    final completer = Completer<Uint8List?>();
    _gpioReadCompleter = completer;
    _gpioReadTimer = Timer(timeout, () => _finishGpioRead(null));
    _completeGpioReadIfReady();
    return completer.future;
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
      _markUartSocketClosed();
      _finishUartRead(null);
      try {
        _clientOnEnd?.call(e, expectedClosure);
      } catch (_) {}
      _scheduleProactiveReconnect();
    }, onDone: () {
      _markUartSocketClosed();
      _finishUartRead(null);
      try {
        _clientOnEnd?.call('Socket closed', true);
      } catch (_) {}
      _scheduleProactiveReconnect();
    }, cancelOnError: true);
  }

  void _markUartSocketClosed() {
    if (_usingNetwork && !expectedClosure) {
      _disconnectDetectedAt ??= DateTime.now();
    }
    try {
      _socketSubscription?.cancel().catchError((_) {});
    } catch (_) {}
    _socketSubscription = null;
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _uartRxBuffer.clear();
    _finishUartRead(null);
    _consecutiveRecvFailures = 0;
  }

  void _scheduleProactiveReconnect() {
    if (_proactiveReconnectLoopActive) return;
    if (!_usingNetwork || expectedClosure) return;
    _proactiveReconnectLoopActive = true;
    () async {
      try {
        while (_usingNetwork && !expectedClosure && _socket == null) {
          final ok = await _maybeReconnectNetwork();
          if (ok) break;
          await Future.delayed(const Duration(milliseconds: 150));
        }
      } finally {
        _proactiveReconnectLoopActive = false;
      }
    }();
  }

  Future<bool> _maybeReconnectNetwork() async {
    if (expectedClosure) return false;
    final last = _lastNetworkReconnectAttempt;
    final requiredBackoff = _currentReconnectBackoff();
    if (last != null && DateTime.now().difference(last) < requiredBackoff) {
      return false;
    }
    _lastNetworkReconnectAttempt = DateTime.now();

    if (!_usingNetwork || _networkHost.isEmpty || _networkUartPort <= 0) {
      return false;
    }

    try {
      _markUartSocketClosed();
      expectedClosure = false;
      _socket = await Socket.connect(
        _networkHost,
        _networkUartPort,
        timeout: enableFastReconnectTuning
            ? const Duration(seconds: 3)
            : const Duration(seconds: 5),
      );
      _attachUartSubscription();
      final ok = await _uartSendConfig(_networkBaud);
      if (!ok) throw 'UARTIP CONFIG failed after reconnect';
      try {
        if (_networkGpioPort != null &&
            _networkGpioPort! > 0 &&
            _networkGpioPort! <= 65535) {
          await _connectGpio();
          await _initializeGpioSequence();
        }
      } catch (e) {
        logger.w('GPIO-over-IP reconnect failed (non-fatal): $e');
      }
      _startRecvPolling();
      if (_disconnectDetectedAt != null) {
        final elapsed =
            DateTime.now().difference(_disconnectDetectedAt!).inMilliseconds;
        logger.i('Reconnect latency: ${elapsed}ms');
        _disconnectDetectedAt = null;
      }
      _networkReconnectFailures = 0;
      return true;
    } catch (e) {
      logger.w('UART-over-IP reconnect failed: $e');
      _markUartSocketClosed();
      final nextFailures = _networkReconnectFailures + 1;
      _networkReconnectFailures = nextFailures > 8 ? 8 : nextFailures;
      return false;
    }
  }

  Duration _currentReconnectBackoff() {
    if (!enableFastReconnectTuning) return const Duration(seconds: 2);
    if (_networkReconnectFailures <= 0) return Duration.zero;
    final shift = _networkReconnectFailures - 1;
    final factor = 1 << (shift > 5 ? 5 : shift);
    final computedMs = baseReconnectBackoff.inMilliseconds * factor;
    final clampedMs = computedMs > maxReconnectBackoff.inMilliseconds
        ? maxReconnectBackoff.inMilliseconds
        : computedMs;
    return Duration(milliseconds: clampedMs);
  }

  Future<Uint8List?> _uartReadExact(int length, Duration timeout) async {
    if (length <= 0) return Uint8List(0);
    if (_uartReadCompleter != null) return null;
    _uartReadNeeded = length;
    final completer = Completer<Uint8List?>();
    _uartReadCompleter = completer;
    _uartReadTimer = Timer(timeout, () => _finishUartRead(null));
    _completeUartReadIfReady();
    return completer.future;
  }

  Future<Uint8List?> _uartReadExactWithEscalation(
    int length,
    Duration primaryTimeout, {
    Duration? fallbackTimeout,
  }) async {
    final first = await _uartReadExact(length, primaryTimeout);
    if (first != null) return first;
    if (!enableFastReconnectTuning) return null;
    final fallback = fallbackTimeout;
    if (fallback == null || fallback <= primaryTimeout) return null;
    return _uartReadExact(length, fallback);
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
    if (c != null && !c.isCompleted) c.complete(data);
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
    if (_socket == null) return false;
    return _withIoLock<bool>(() async {
      try {
        final header = _uartHeader12(op: 0x01, param: 0);
        final payload = BytesBuilder();
        payload.add([0x01, 0x04]);
        payload.add(_u32be(baud));
        payload.add([0x00]);
        await _socketWrite(header);
        await _socketWrite(payload.toBytes());
        final ack = await _uartReadExactWithEscalation(
          12,
          enableFastReconnectTuning ? fastAckTimeout : slowAckTimeout,
          fallbackTimeout: slowAckTimeout,
        );
        if (ack == null || ack.length < 12) return false;
        if (!_checkReplyHeader12(ack, 0x01)) return false;
        final status = _u32beRead(ack, 8);
        if (status != 0) return false;
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  Future<bool> _uartSendFramed(Uint8List data) async {
    if (_socket == null) return false;
    return _withIoLock<bool>(() async {
      try {
        final header = _uartHeader12(op: 0x02, param: 0);
        final length = data.length & 0xFFFF;
        final sub =
            Uint8List.fromList([0x01, (length >> 8) & 0xFF, length & 0xFF]);
        await _socketWrite(header);
        await _socketWrite(sub);
        await _socketWrite(data);
        final ack = await _uartReadExactWithEscalation(
          12,
          enableFastReconnectTuning ? fastAckTimeout : slowAckTimeout,
          fallbackTimeout: slowAckTimeout,
        );
        if (ack == null || ack.length < 12) return false;
        if (!_checkReplyHeader12(ack, 0x02)) return false;
        final status = _u32beRead(ack, 8);
        if (status != 0) return false;
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  Future<void> _socketWrite(List<int> bytes) async {
    final prior = _writeMutex;
    final current = Completer<void>();
    _writeMutex = current;
    try {
      if (prior != null) await prior.future;
      final sock = _socket;
      if (sock == null) throw StateError('UARTIP socket is closed');
      sock.add(bytes);
    } finally {
      if (!current.isCompleted) current.complete();
      if (identical(_writeMutex, current)) _writeMutex = null;
    }
  }

  Future<T> _withIoLock<T>(Future<T> Function() action) async {
    final prior = _ioMutex;
    final current = Completer<void>();
    _ioMutex = current;
    try {
      if (prior != null) await prior.future;
      return await action();
    } finally {
      if (!current.isCompleted) current.complete();
      if (identical(_ioMutex, current)) _ioMutex = null;
    }
  }

  void _startRecvPolling() {
    if (_recvPolling) return;
    _recvPolling = true;
    () async {
      while (_usingNetwork && _socket != null && _recvPolling) {
        final recvTimeout =
            (enableFastReconnectTuning && _consecutiveRecvFailures < 3)
                ? const Duration(milliseconds: 250)
                : slowRecvTimeout;
        final ok = await _uartRecvOnce(1024, recvTimeout);
        if (!ok) {
          _consecutiveRecvFailures++;
          if (_socket == null) {
            _scheduleProactiveReconnect();
            break;
          }
          if (_consecutiveRecvFailures >= 3) {
            final reconnected = await _maybeReconnectNetwork();
            if (reconnected) {
              _consecutiveRecvFailures = 0;
              break;
            }
          }
          await Future.delayed(enableFastReconnectTuning
              ? const Duration(milliseconds: 10)
              : const Duration(milliseconds: 20));
        } else {
          _consecutiveRecvFailures = 0;
        }
      }
      _recvPolling = false;
      if (_usingNetwork && !expectedClosure && _socket == null) {
        _scheduleProactiveReconnect();
      }
    }();
  }

  Future<bool> _uartRecvOnce(int maxBytes, Duration timeout) async {
    if (_socket == null) return false;
    return _withIoLock<bool>(() async {
      try {
        final header = _uartHeader12(op: 0x03, param: 0);
        final want = maxBytes & 0xFFFF;
        final sub = Uint8List.fromList([0x01, (want >> 8) & 0xFF, want & 0xFF]);
        await _socketWrite(header);
        await _socketWrite(sub);
        final ack = await _uartReadExactWithEscalation(
          12,
          timeout,
          fallbackTimeout: slowRecvTimeout,
        );
        if (ack == null || ack.length < 12) return false;
        if (!_checkReplyHeader12(ack, 0x03)) return false;
        final status = _u32beRead(ack, 8);
        if (status != 0) return true;
        final subhdr = await _uartReadExactWithEscalation(
          3,
          timeout,
          fallbackTimeout: slowRecvTimeout,
        );
        if (subhdr == null || subhdr.length != 3) return false;
        final len = ((subhdr[1] & 0xFF) << 8) | (subhdr[2] & 0xFF);
        if (len > 0) {
          final data = await _uartReadExactWithEscalation(
            len,
            timeout,
            fallbackTimeout: slowRecvTimeout,
          );
          if (data == null || data.length != len) return false;
          try {
            _clientOnData?.call(data);
          } catch (_) {}
        }
        return true;
      } catch (_) {
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
    if (_gpioSocket == null) return;
    var ok = true;
    ok = (await _gpioSendLevel(gpioIndex: 4, level: 1)) && ok;
    ok = (await _gpioSendLevel(gpioIndex: 5, level: 1)) && ok;
    await Future.delayed(const Duration(milliseconds: 250));
    if (_gpioSocket != null) {
      ok = (await _gpioSendLevel(gpioIndex: 5, level: 0)) && ok;
      ok = (await _gpioSendLevel(gpioIndex: 4, level: 0)) && ok;
    }
    if (!ok) {
      logger.w('GPIO reset/power-cycle sequence had errors');
    }
  }
}
