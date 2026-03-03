// Serial Helper for Standalone direct UART with GPIO
import 'dart:io';
import 'dart:typed_data';
import 'package:orbit/logging.dart';
import 'package:orbit/serial_helper/serial_helper_standalone_uart.dart';

class StandaloneUartGpioHelper {
  static const int _defaultResetPin = 136;
  static const int _defaultPowerPin = 137;
  static final Uint8List _uartGpioWakeSequence =
      Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);

  final StandaloneUartHelper _uart = StandaloneUartHelper();
  int _resetPin = _defaultResetPin;
  int _powerPin = _defaultPowerPin;
  bool _gpioActive = false;
  int _rawRxChunkLogCount = 0;

  Future<List<Object>> listPorts() => _uart.listPorts();
  Future<bool> ensureSerialPermission() => _uart.ensureSerialPermission();
  Future<String> getPortName(Object port) => _uart.getPortName(port);

  Future<bool> openPort(Object? port, int baud) async {
    final rawPort = (port ?? '').toString();
    final parsed = _parsePortConfig(port);
    _resetPin = parsed.$2;
    _powerPin = parsed.$3;
    logger.i(
        'UART GPIO open requested: raw: "$rawPort" parsedPort: "${parsed.$1}" '
        'rst: $_resetPin pwr: $_powerPin baud: $baud');

    final opened = await _uart.openPort(
      parsed.$1,
      baud,
    );
    if (!opened) {
      logger.e(
          'UART GPIO: underlying UART open failed for "${parsed.$1}" (from "$rawPort").');
      return false;
    }

    if (!_supportsSysfsGpio()) {
      logger.w(
          'UART GPIO transport selected on unsupported host (${Platform.operatingSystem})');
      _gpioActive = false;
      return true;
    }

    final gpioOk = await _gpioInit();
    if (!gpioOk) {
      logger.e('UART GPIO init failed (rst: $_resetPin pwr: $_powerPin)');
      await _uart.closePort();
      return false;
    }

    final powered = await _gpioPowerup();
    if (!powered) {
      logger.e('UART GPIO power-up sequence failed');
      await _uart.closePort();
      return false;
    }

    final wakeOk = await _sendUartGpioWakeSequence();
    if (!wakeOk) {
      logger.e('UART GPIO wake sequence failed');
      await _uart.closePort();
      return false;
    }

    _gpioActive = true;
    logger.i('UART GPIO open sequence complete');
    return true;
  }

  bool _supportsSysfsGpio() {
    return Platform.isLinux || Platform.isAndroid;
  }

  Future<bool> reconfigureBaud(int baud) => _uart.reconfigureBaud(baud);

  Future<int> writeData(Uint8List data) => _uart.writeData(data);

  Future<void> readData(
    Function(Uint8List) onData,
    Function(Object, bool) onEnd,
  ) {
    return _uart.readData(
      (chunk) {
        if (_rawRxChunkLogCount < 120) {
          _rawRxChunkLogCount++;
          final int sampleLen = chunk.length > 32 ? 32 : chunk.length;
          logger.i(
              'UART GPIO raw chunk #$_rawRxChunkLogCount: len: ${chunk.length} sample: ${chunk.take(sampleLen).toList()}');
        }
        onData(chunk);
      },
      onEnd,
    );
  }

  Future<bool> closePort() async {
    if (_gpioActive) {
      try {
        await _gpioPowerdown();
      } catch (e) {
        logger.w('UART GPIO powerdown failed: $e');
      }
    }
    _gpioActive = false;
    return _uart.closePort();
  }

  (String, int, int) _parsePortConfig(Object? port) {
    final raw = (port ?? '').toString().trim();
    if (raw.isEmpty) return ('', _defaultResetPin, _defaultPowerPin);

    final parts =
        raw.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return (raw, _defaultResetPin, _defaultPowerPin);

    final portName = parts.first;
    final int? reset = parts.length >= 2 ? int.tryParse(parts[1]) : null;
    final int? power = parts.length >= 3 ? int.tryParse(parts[2]) : null;
    if (parts.length >= 2 && reset == null) {
      logger
          .w('UART GPIO: invalid reset pin token "${parts[1]}", using default');
    }
    if (parts.length >= 3 && power == null) {
      logger
          .w('UART GPIO: invalid power pin token "${parts[2]}", using default');
    }
    return (
      portName,
      reset ?? _defaultResetPin,
      power ?? _defaultPowerPin,
    );
  }

  Future<bool> _gpioInit() async {
    final dirReset = await _gpioSetDirectionOut(_resetPin);
    if (!dirReset) return false;
    final resetInit = await _gpioToggleLogical(_resetPin, 1);
    if (!resetInit) return false;

    final dirPower = await _gpioSetDirectionOut(_powerPin);
    if (!dirPower) return false;
    final powerInit = await _gpioToggleLogical(_powerPin, 0);
    if (!powerInit) return false;

    await Future<void>.delayed(const Duration(milliseconds: 250));
    return true;
  }

  Future<bool> _gpioPowerup() async {
    final p1 = await _gpioToggleLogical(_powerPin, 1);
    if (!p1) return false;
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final p2 = await _gpioToggleLogical(_resetPin, 0);
    if (!p2) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return true;
  }

  Future<bool> _gpioPowerdown() async {
    final p1 = await _gpioToggleLogical(_resetPin, 1);
    if (!p1) return false;
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final p2 = await _gpioToggleLogical(_powerPin, 0);
    if (!p2) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    return true;
  }

  Future<bool> _gpioSetDirectionOut(int pin) async {
    final gpioRoot = Directory('/sys/class/gpio');
    if (!await gpioRoot.exists()) {
      logger.e('GPIO sysfs root not found: /sys/class/gpio');
      return false;
    }
    final pinDir = Directory('/sys/class/gpio/gpio$pin');
    if (!await pinDir.exists()) {
      final exported = await _exportPin(pin);
      if (!exported) return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return _writeText('/sys/class/gpio/gpio$pin/direction', 'out');
  }

  Future<bool> _exportPin(int pin) async {
    final exportFile = File('/sys/class/gpio/export');
    try {
      await exportFile.writeAsString('$pin');
      return true;
    } catch (e) {
      final pinDir = Directory('/sys/class/gpio/gpio$pin');
      if (await pinDir.exists()) {
        return true;
      }
      logger.w('Failed to export GPIO $pin: $e');
      return false;
    }
  }

  Future<bool> _gpioToggleLogical(int pin, int logicalLevel) async {
    final int wireLevel;
    if (pin == _powerPin) {
      wireLevel = logicalLevel == 0 ? 0 : 1;
    } else if (pin == _resetPin) {
      wireLevel = logicalLevel == 0 ? 1 : 0;
    } else {
      wireLevel = logicalLevel == 0 ? 0 : 1;
    }
    return _writeText('/sys/class/gpio/gpio$pin/value', '$wireLevel');
  }

  Future<bool> _writeText(String path, String value) async {
    try {
      await File(path).writeAsString(value);
      return true;
    } catch (e) {
      logger.w('GPIO write failed for $path: $e');
      return false;
    }
  }

  Future<bool> _sendUartGpioWakeSequence() async {
    try {
      final int written = await _uart.writeData(_uartGpioWakeSequence);
      if (written < 0) {
        logger.e('UART GPIO wake sequence write returned $written');
        return false;
      }
      logger.i(
          'UART GPIO wake sequence sent (${_uartGpioWakeSequence.length} bytes)');
      return true;
    } catch (e) {
      logger.e('UART GPIO wake sequence exception: $e');
      return false;
    }
  }
}
