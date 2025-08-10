import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'dart:developer';

var logger = Logger(
  filter: DebugFilter(),
  printer: PrettyPrinter(
    stackTraceBeginIndex: 1,
    methodCount: 2,
    errorMethodCount: 150,
    lineLength: 120,
    colors: true,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.none,
    excludeBox: {Level.all: true},
    noBoxingByDefault: true,
    levelEmojis: {
      Level.debug: '🔵',
      Level.info: '🟢',
      Level.warning: '🟠',
      Level.error: '🔴',
      Level.fatal: '🔴',
    },
  ),
  output: MultiOutput([
    DeveloperConsoleOutput(),
  ]),
);

class DebugFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    return kDebugMode;
  }
}

class DeveloperConsoleOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    final StringBuffer buffer = StringBuffer();
    event.lines.forEach(buffer.writeln);
    log(
      buffer.toString().replaceAll('[38;5;12m', '').replaceAll('[0m', '').replaceAll('[38;5;196m', '').replaceAll('[38;5;208m', ''),
      level: event.level.value,
      error: event.origin.error,
      stackTrace: event.origin.stackTrace,
    );
  }
}


void logd(dynamic text, {StackTrace? stackTrace}) {
  logger.d(text, stackTrace: stackTrace);
}

void logi(dynamic text, {StackTrace? stackTrace}) {
  logger.i(text, stackTrace: stackTrace);
}

void logw(dynamic text, {StackTrace? stackTrace}) {
  logger.w(text, stackTrace: stackTrace);
}

void loge(dynamic text, {StackTrace? stackTrace}) {
  logger.e(text, stackTrace: stackTrace);
}