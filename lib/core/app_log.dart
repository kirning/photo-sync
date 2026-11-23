import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

class LogEntry {
  LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  String get formatted {
    final t = time.toIso8601String().substring(11, 19);
    final lv = switch (level) {
      LogLevel.debug => 'D',
      LogLevel.info => 'I',
      LogLevel.warn => 'W',
      LogLevel.error => 'E',
    };
    return '$t $lv/$tag $message';
  }

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'level': level.name,
        'tag': tag,
        'message': message,
      };

  static LogEntry fromJson(Map<String, dynamic> json) => LogEntry(
        time: DateTime.tryParse('${json['time']}') ?? DateTime.now(),
        level: LogLevel.values.firstWhere(
          (e) => e.name == json['level'],
          orElse: () => LogLevel.info,
        ),
        tag: '${json['tag'] ?? '-'}',
        message: '${json['message'] ?? ''}',
      );
}

/// 应用内滚动日志，方便在没有 adb 的情况下从设置页排查问题。
class AppLog extends ChangeNotifier {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int _maxEntries = 600;

  final List<LogEntry> _entries = <LogEntry>[];

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries.reversed);

  void debug(String tag, String message) => _add(LogLevel.debug, tag, message);

  void info(String tag, String message) => _add(LogLevel.info, tag, message);

  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);

  void error(String tag, String message, [Object? cause]) {
    _add(LogLevel.error, tag, cause == null ? message : '$message: $cause');
  }

  void _add(LogLevel level, String tag, String message) {
    _entries.add(LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    ));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String dump() => _entries.map((e) => e.formatted).join('\n');
}
