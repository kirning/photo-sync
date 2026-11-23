import 'dart:math' as math;

/// 通用格式化工具。
class Fmt {
  const Fmt._();

  static String bytes(int value) {
    if (value < 0) return '-';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final text = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(size >= 100 ? 0 : 1);
    return '$text ${units[unit]}';
  }

  static String count(int value) {
    if (value < 10000) return '$value';
    if (value < 100000000) return '${(value / 10000).toStringAsFixed(1)} 万';
    return '${(value / 100000000).toStringAsFixed(2)} 亿';
  }

  static String duration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} 秒';
    if (d.inMinutes < 60) return '${d.inMinutes} 分 ${d.inSeconds % 60} 秒';
    return '${d.inHours} 时 ${d.inMinutes % 60} 分';
  }

  static String percent(double value) {
    if (value.isNaN || value.isInfinite) return '0%';
    return '${(value.clamp(0, 1) * 100).toStringAsFixed(1)}%';
  }

  /// 2026-11-23 20:51
  static String dateTime(DateTime value) {
    String two(int v) => v.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  static String date(DateTime value) {
    String two(int v) => v.toString().padLeft(2, '0');
    final local = value.toLocal();
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }

  static String relative(DateTime value) {
    final diff = DateTime.now().difference(value);
    if (diff.inSeconds < 45) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return date(value);
  }

  static String eta(int remainingBytes, double bytesPerSecond) {
    if (bytesPerSecond <= 0 || remainingBytes <= 0) return '--';
    final seconds = math.max(1, (remainingBytes / bytesPerSecond).ceil());
    return duration(Duration(seconds: seconds));
  }
}
