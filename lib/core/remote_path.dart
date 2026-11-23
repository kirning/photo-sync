/// 远端路径拼装与清洗。
///
/// 不同存储对路径的约束不同：
/// - WebDAV：绝对路径，允许中文；
/// - S3：Object Key，无目录概念；
/// - SMB：以 share 名为第一段的绝对路径。
///
/// 因此这里统一产出“相对路径片段”，由各存储实现决定加不加前导 `/`。
class RemotePathUtil {
  const RemotePathUtil._();

  static const String defaultFolderTemplate = '{album}/{yyyy}/{MM}';

  /// 模板可用变量：{album} {yyyy} {yy} {MM} {dd} {yyyyMMdd}
  static const List<String> templateVariables = [
    '{album}',
    '{yyyy}',
    '{yy}',
    '{MM}',
    '{dd}',
    '{yyyyMMdd}',
  ];

  static String normalizeRoot(String root) {
    var value = root.trim().replaceAll('\\', '/');
    value = value.replaceAll(RegExp(r'/+'), '/');
    while (value.startsWith('/')) {
      value = value.substring(1);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) return '';
    return value
        .split('/')
        .where((e) => e.isNotEmpty && e != '.' && e != '..')
        .map(sanitizeSegment)
        .join('/');
  }

  /// 清洗单个路径片段，去掉文件系统不允许的字符。
  static String sanitizeSegment(String input, {String fallback = '未命名'}) {
    var value = input
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    value = value.replaceAll(RegExp(r'^\.+'), '').replaceAll(RegExp(r'\.+$'), '');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (value.isEmpty) value = fallback;
    // Windows/SMB 保留名
    const reserved = {
      'CON', 'PRN', 'AUX', 'NUL', //
      'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
      'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
    };
    if (reserved.contains(value.toUpperCase())) value = '_$value';
    if (value.length > 100) value = value.substring(0, 100);
    return value;
  }

  static String sanitizeFileName(String input) {
    final dot = input.lastIndexOf('.');
    if (dot <= 0 || dot == input.length - 1) {
      return sanitizeSegment(input, fallback: '未命名文件');
    }
    final name = sanitizeSegment(input.substring(0, dot), fallback: '未命名文件');
    final ext = input
        .substring(dot + 1)
        .replaceAll(RegExp(r'[^A-Za-z0-9]'), '')
        .toLowerCase();
    return ext.isEmpty ? name : '$name.$ext';
  }

  /// 根据模板生成目录片段（不含文件名）。
  static List<String> folderSegments({
    required String template,
    required String albumName,
    required DateTime date,
  }) {
    final tpl = template.trim().isEmpty ? defaultFolderTemplate : template.trim();
    final replaced = tpl
        .replaceAll('{album}', sanitizeSegment(albumName))
        .replaceAll('{yyyy}', date.year.toString().padLeft(4, '0'))
        .replaceAll('{yy}', (date.year % 100).toString().padLeft(2, '0'))
        .replaceAll('{MM}', date.month.toString().padLeft(2, '0'))
        .replaceAll('{dd}', date.day.toString().padLeft(2, '0'))
        .replaceAll('{yyyyMMdd}', '${date.year.toString().padLeft(4, '0')}'
            '${date.month.toString().padLeft(2, '0')}'
            '${date.day.toString().padLeft(2, '0')}');
    return replaced
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != '.' && e != '..')
        .map((e) => sanitizeSegment(e))
        .toList(growable: false);
  }

  /// 拼接相对路径，返回 `a/b/c` 形式（无前导斜杠）。
  static String join(Iterable<String> parts) {
    final cleaned = <String>[];
    for (final part in parts) {
      final value = part.trim().replaceAll('\\', '/');
      for (final segment in value.split('/')) {
        final s = segment.trim();
        if (s.isEmpty || s == '.') continue;
        if (s == '..') {
          if (cleaned.isNotEmpty) cleaned.removeLast();
          continue;
        }
        cleaned.add(s);
      }
    }
    return cleaned.join('/');
  }

  static String dirname(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return '';
    return normalized.substring(0, index);
  }

  static String basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  /// 重名时追加 (1)/(2)...，保留扩展名。
  static String uniqueFileName(String desired, Set<String> takenLowercase) {
    final safe = sanitizeFileName(desired);
    final lower = safe.toLowerCase();
    if (!takenLowercase.contains(lower)) return safe;
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    for (var i = 1; i < 10000; i++) {
      final candidate = '$base ($i)$ext';
      if (!takenLowercase.contains(candidate.toLowerCase())) return candidate;
    }
    return '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }
}
