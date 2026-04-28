import 'package:flutter/foundation.dart';

enum CoduxLogLevel { debug, info, warn, error, off }

class CoduxLog {
  CoduxLog._();

  static const _levelName = String.fromEnvironment(
    'CODUX_LOG_LEVEL',
    defaultValue: 'warn',
  );

  static final CoduxLogLevel level = _parse(_levelName);

  static String get nativeLevelName => level.name;

  static void debug(String message) => _print(CoduxLogLevel.debug, message);

  static void info(String message) => _print(CoduxLogLevel.info, message);

  static void warn(String message) => _print(CoduxLogLevel.warn, message);

  static void error(String message) => _print(CoduxLogLevel.error, message);

  static void _print(CoduxLogLevel messageLevel, String message) {
    if (!_enabled(messageLevel)) return;
    debugPrint(message);
  }

  static bool _enabled(CoduxLogLevel messageLevel) {
    if (level == CoduxLogLevel.off) return false;
    return messageLevel.index >= level.index;
  }

  static CoduxLogLevel _parse(String value) {
    final normalized = value.trim().toLowerCase();
    for (final item in CoduxLogLevel.values) {
      if (item.name == normalized) return item;
    }
    return CoduxLogLevel.warn;
  }
}
