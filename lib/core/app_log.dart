import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

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

  /// 日志文件超过这个大小就轮转成 `app.log.1`。
  static const int _maxFileBytes = 512 * 1024;

  final List<LogEntry> _entries = <LogEntry>[];

  File? _logFile;
  IOSink? _sink;
  bool _persisting = false;
  int _writtenBytes = 0;

  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries.reversed);

  /// 打开落盘日志。放在 `AppPaths.logsDir/app.log`，`导出` 时可以整体取出。
  ///
  /// 每个 isolate 各自调用一次（UI 与后台上传服务是两个 isolate）。
  Future<void> init(Directory logsDir) async {
    try {
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }
      final file = File('${logsDir.path}${Platform.pathSeparator}app.log');
      if (await file.exists()) {
        _writtenBytes = await file.length();
        if (_writtenBytes > _maxFileBytes) {
          final rotated = File('${file.path}.1');
          if (await rotated.exists()) await rotated.delete();
          await file.rename(rotated.path);
          _writtenBytes = 0;
        }
      }
      _logFile = file;
      _sink = file.openWrite(mode: FileMode.append);
      _persisting = true;
      info('app', '日志已开启：${file.path}');
    } catch (error) {
      _persisting = false;
      debug('app', '日志落盘失败：$error');
    }
  }

  /// 把内存里的日志与落盘的日志一起取出，用于「导出日志」。
  Future<String> readPersisted() async {
    final file = _logFile;
    if (file == null) return dump();
    try {
      await _sink?.flush();
      if (!await file.exists()) return dump();
      final text = await file.readAsString();
      return text.length > 400000 ? text.substring(text.length - 400000) : text;
    } catch (error) {
      return '${dump()}\n读取日志文件失败：$error';
    }
  }

  Future<void> closeFile() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {
      // 关闭失败无所谓
    }
    _sink = null;
    _persisting = false;
  }

  void debug(String tag, String message) => _add(LogLevel.debug, tag, message);

  void info(String tag, String message) => _add(LogLevel.info, tag, message);

  void warn(String tag, String message) => _add(LogLevel.warn, tag, message);

  void error(String tag, String message, [Object? cause]) {
    _add(LogLevel.error, tag, cause == null ? message : '$message: $cause');
  }

  void _add(LogLevel level, String tag, String message) {
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _writeThrough(entry);
    notifyListeners();
  }

  /// 同时写文件与 logcat，出问题时即使拿不到 UI 也能用 `adb logcat` 看到。
  void _writeThrough(LogEntry entry) {
    try {
      // release 包同样会输出到 logcat（tag: flutter）。
      developer.log(
        entry.formatted,
        name: 'photo_sync.${entry.tag}',
        level: switch (entry.level) {
          LogLevel.error => 1000,
          LogLevel.warn => 900,
          LogLevel.info => 800,
          LogLevel.debug => 500,
        },
      );
    } catch (_) {
      // 日志转发失败不影响业务
    }
    final sink = _sink;
    if (!_persisting || sink == null) return;
    try {
      final line = '${entry.time.toIso8601String()} ${entry.formatted}\n';
      sink.write(line);
      _writtenBytes += line.length;
      if (_writtenBytes > _maxFileBytes) {
        unawaited(_rotate());
      }
    } catch (_) {
      // 写日志失败不影响业务
    }
  }

  Future<void> _rotate() async {
    final file = _logFile;
    final sink = _sink;
    if (file == null || sink == null) return;
    _persisting = false;
    try {
      await sink.flush();
      await sink.close();
      final rotated = File('${file.path}.1');
      if (await rotated.exists()) await rotated.delete();
      await file.rename(rotated.path);
      _sink = file.openWrite(mode: FileMode.append);
      _writtenBytes = 0;
      _persisting = true;
    } catch (_) {
      _sink = null;
      _persisting = false;
    }
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String dump() => _entries.map((e) => e.formatted).join('\n');
}
