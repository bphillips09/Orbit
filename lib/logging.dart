// Logging class
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppLogger {
  AppLogger._internal();
  static final AppLogger instance = AppLogger._internal();

  Logger? _logger;
  Level _currentLevel = kDebugMode ? Level.debug : Level.info;
  IOSink? _fileSink;
  File? _logFile;
  static const int _maxBytes = 1024 * 1024; // 1 MiB
  static const int _maxRotations = 3;
  LogOutput? _output;
  LogPrinter? _printer;
  final String _fileExtension =
      defaultTargetPlatform == TargetPlatform.android ? '.txt' : '.log';

  Level get currentLevel => _currentLevel;
  String? get logFilePath => _logFile?.path;

  // Initialize with console output only; file output will be attached later
  Future<void> init({Level? level}) async {
    _currentLevel = level ?? _currentLevel;
    final outputs = <LogOutput>[ConsoleOutput()];
    _output = MultiOutput(outputs);

    final consolePrinter = PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 5,
      lineLength: 120,
      colors: false,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.dateAndTime,
    );

    final filePrinter = SimplePrinter(printTime: true);

    final printer = HybridPrinter(
      consolePrinter,
      trace: filePrinter,
      debug: filePrinter,
      info: filePrinter,
      warning: filePrinter,
      error: filePrinter,
      fatal: filePrinter,
    );

    _printer = printer;
    _logger = Logger(
      level: _currentLevel,
      printer: _printer!,
      output: _output,
      filter: kReleaseMode ? ProductionFilter() : DevelopmentFilter(),
    );
  }

  // Ensure file output is initialized once the Flutter binding is ready
  Future<void> ensureFileOutputReady() async {
    if (kIsWeb || kIsWasm) return;
    if (_fileSink != null) return;

    try {
      final dir = await getApplicationSupportDirectory();
      final logsDir = Directory(p.join(dir.path, 'logs'));
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }
      _logFile = File(p.join(logsDir.path, 'orbit$_fileExtension'));
      await _maybeRotateLogs();
      _fileSink = _logFile!.openWrite(mode: FileMode.append);

      // Rebuild outputs to include file sink
      final outputs = <LogOutput>[ConsoleOutput(), _FileSinkOutput(_fileSink!)];
      _output = MultiOutput(outputs);
      _logger = Logger(
        level: _currentLevel,
        printer: _printer ?? PrettyPrinter(),
        output: _output,
        filter: kReleaseMode ? ProductionFilter() : DevelopmentFilter(),
      );
    } catch (_) {
      // Ignore file init errors, console logging still works
    }
  }

  // Rotate the logs if they are too large
  Future<void> _maybeRotateLogs() async {
    try {
      if (_logFile == null) return;
      if (!await _logFile!.exists()) return;
      final int size = await _logFile!.length();
      if (size < _maxBytes) return;

      // Close the current sink first
      await _fileSink?.flush();
      await _fileSink?.close();
      _fileSink = null;

      for (int i = _maxRotations - 1; i >= 1; i--) {
        final rotated =
            File(p.join(_logFile!.parent.path, 'orbit$_fileExtension.$i'));
        final next = File(
            p.join(_logFile!.parent.path, 'orbit$_fileExtension.${i + 1}'));
        if (await rotated.exists()) {
          if (await next.exists()) {
            await next.delete();
          }
          await rotated.rename(next.path);
        }
      }

      // Move the current log to .1 and recreate an empty current log
      final first =
          File(p.join(_logFile!.parent.path, 'orbit$_fileExtension.1'));
      if (await first.exists()) {
        await first.delete();
      }
      await _logFile!.rename(first.path);
      _logFile = File(p.join(_logFile!.parent.path, 'orbit$_fileExtension'));
      await _logFile!.create(recursive: true);
    } catch (_) {
      // Swallow any rotation errors
    }
  }

  // Set the logging level
  void setLevel(Level level) {
    _currentLevel = level;
    _logger = Logger(
      level: _currentLevel,
      printer: _printer ?? PrettyPrinter(),
      output: _output ?? ConsoleOutput(),
      filter: kReleaseMode ? ProductionFilter() : DevelopmentFilter(),
    );
  }

  Logger get logger {
    _logger ??= Logger(
      level: _currentLevel,
      printer: _printer ?? PrettyPrinter(),
      output: _output ?? ConsoleOutput(),
      filter: kReleaseMode ? ProductionFilter() : DevelopmentFilter(),
    );
    return _logger!;
  }

  // Run the given function with logging
  Future<void> runWithLogging(FutureOr<void> Function() body) async {
    if (_logger == null) {
      await init();
    }
    final completer = Completer<void>();
    runZonedGuarded(
      () {
        runZoned(
          () {
            Future.sync(body)
                .then((_) => completer.complete())
                .catchError((error, stack) {
              try {
                logger.e('Uncaught error: $error',
                    error: error, stackTrace: stack);
              } catch (_) {
                // ignore: avoid_print
                print('Uncaught error: $error\n$stack');
              }
              if (!completer.isCompleted) {
                completer.completeError(error, stack);
              }
            });
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, message) {
              // Don't log via logger here to avoid recursion
              parent.print(zone, message);
            },
          ),
        );
      },
      (error, stack) {
        try {
          logger.e('Uncaught error: $error', error: error, stackTrace: stack);
        } catch (_) {
          // ignore: avoid_print
          print('Uncaught error: $error\n$stack');
        }
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      },
    );
    return completer.future;
  }

  // Flush and close the file sink
  Future<void> dispose() async {
    await _fileSink?.flush();
    await _fileSink?.close();
    _fileSink = null;
  }
}

// File sink output for multi-output
class _FileSinkOutput extends LogOutput {
  final IOSink sink;
  _FileSinkOutput(this.sink);

  @override
  void output(OutputEvent event) {
    for (var line in event.lines) {
      sink.writeln(line);
    }
  }
}

// Get the logger
Logger get logger => AppLogger.instance.logger;
