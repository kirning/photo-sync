import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// 崩溃与未捕获异常记录。
///
/// 应用在 release 模式下一旦出现未捕获异常或原生异常，进程往往直接结束，
/// 用户看不到任何信息。这里把 Dart 侧未捕获异常和 Android 侧异常写进同一个
/// 目录（应用私有 files 目录）下的 `crash.log` / `native_crash.log`，
/// 下次启动时在「运行日志」页展示，并可复制或导出到手机存储。
class CrashLog {
  CrashLog._();

  static File? _file;
  static Directory? _root;
  static bool _installed = false;

  /// 本次会话是否有新的错误被记录（用于界面提示）。
  static int sessionErrorCount = 0;

  /// 最近一次记录的错误摘要，供界面直接展示。
  static String? lastSummary;

  static const int _maxBytes = 200 * 1024;

  /// 安装全局异常处理器，并准备日志文件。必须在 `runApp` 之前调用。
  static Future<void> init(Directory root) async {
    _root = root;
    _file = File('${root.path}/crash.log');
    if (_installed) return;
    _installed = true;

    FlutterError.onError = (FlutterErrorDetails details) {
      final error = details.exceptionAsString();
      record('flutter', error, details.stack);
      // 保留 Flutter 默认的控制台输出，方便连电脑时看 logcat。
      FlutterError.presentError(details);
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record('async', '$error', stack);
      // 返回 true 表示已处理，避免再次抛到平台层。
      return true;
    };
  }

  /// 记录一条错误。可以安全地在任意 isolate 调用。
  static void record(String kind, String message, [StackTrace? stack]) {
    sessionErrorCount++;
    final buffer = StringBuffer()
      ..writeln('===== ${DateTime.now().toIso8601String()} [$kind] =====')
      ..writeln(message);
    if (stack != null) buffer.writeln(stack);
    final text = buffer.toString();
    lastSummary = text.split('\n').firstWhere(
          (line) => line.trim().isNotEmpty,
          orElse: () => message,
        );

    AppLog.instance.error('crash', '[$kind] $message');

    final file = _file;
    if (file == null) return;
    unawaited(_append(file, text));
  }

  static Future<void> _append(File file, String text) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(text, mode: FileMode.append, flush: true);
      await _trim(file);
    } catch (_) {
      // 记录错误时再出错只能忽略，不能影响主流程。
    }
  }

  static Future<void> _trim(File file) async {
    final length = await file.length();
    if (length <= _maxBytes) return;
    final text = await file.readAsString();
    final keep = text.substring(text.length - _maxBytes ~/ 2);
    await file.writeAsString('（较旧的崩溃记录已截断）\n$keep', flush: true);
  }

  /// 读取崩溃日志：合并 Dart 异常与 Android 原生异常，最新的在后。
  static Future<String> read() async {
    final root = _root;
    if (root == null) return '';
    final parts = <String>[];
    for (final name in const ['crash.log', 'native_crash.log']) {
      final file = File('${root.path}/$name');
      try {
        if (!await file.exists()) continue;
        final text = await file.readAsString();
        if (text.trim().isEmpty) continue;
        parts.add('----- $name -----\n${text.trim()}');
      } catch (_) {
        // 读取失败忽略
      }
    }
    return parts.join('\n\n');
  }

  static Future<bool> hasContent() => read().then((text) => text.isNotEmpty);

  static Future<void> clear() async {
    final root = _root;
    if (root == null) return;
    for (final name in const ['crash.log', 'native_crash.log']) {
      final file = File('${root.path}/$name');
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // 忽略
      }
    }
  }

  /// 把崩溃日志复制到外部可见目录（Android/data/<包名>/files），
  /// 方便用文件管理器或数据线取走。返回写入的路径，失败返回 null。
  static Future<String?> exportToVisibleDir(Directory? external) async {
    if (external == null) return null;
    final text = await read();
    if (text.isEmpty) return null;
    try {
      final dir = Directory('${external.path}/crash-logs');
      await dir.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('.', '');
      final file = File('${dir.path}/crash-$stamp.txt');
      await file.writeAsString(text, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
