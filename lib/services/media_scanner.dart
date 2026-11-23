import 'dart:io';
import 'dart:isolate';

import '../core/remote_path.dart';
import '../models/album.dart';

/// 常见图片扩展名（小写，不含点）。
const Set<String> imageExtensions = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'dng', 'tif', 'tiff', 'avif',
};

bool isImagePath(String path) {
  final name = RemotePathUtil.basename(path);
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return false;
  return imageExtensions.contains(name.substring(dot + 1).toLowerCase());
}

class BuiltinDirectory {
  const BuiltinDirectory(this.name, this.path);

  final String name;
  final String path;
}

/// 目录扫描器：纯 dart:io，可在 isolate 中运行。
class MediaScanner {
  const MediaScanner._();

  static const Set<String> _skipDirectoryNames = {
    'cache',
    '.cache',
    'thumbnails',
    '.thumbnails',
    'tmp',
    'temp',
    '.trash',
    '.trash-1000',
    'lost.dir',
    'android',
    'obb',
    '.nomedia',
    'recycle',
    r'$recycle.bin',
  };

  /// 常见相册目录（按优先级），只返回实际存在的目录。
  static Future<List<BuiltinDirectory>> discoverCommon() async {
    final home = await _storageRoot();
    final candidates = <BuiltinDirectory>[
      BuiltinDirectory('相机', '$home/DCIM'),
      BuiltinDirectory('相机', '$home/DCIM/Camera'),
      BuiltinDirectory('截图', '$home/Pictures/Screenshots'),
      BuiltinDirectory('截图', '$home/DCIM/Screenshots'),
      BuiltinDirectory('图片', '$home/Pictures'),
      BuiltinDirectory('下载', '$home/Download'),
      BuiltinDirectory('微信', '$home/Pictures/WeiXin'),
      BuiltinDirectory(
        '微信',
        '$home/Android/media/com.tencent.mm/MicroMsg/WeiXin',
      ),
      BuiltinDirectory(
        'WhatsApp',
        '$home/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images',
      ),
      BuiltinDirectory('Telegram', '$home/Pictures/Telegram'),
      BuiltinDirectory('Telegram', '$home/DCIM/Telegram'),
      BuiltinDirectory('Instagram', '$home/Pictures/Instagram'),
    ];

    // 可移动存储卡（/storage/XXXX-XXXX）
    try {
      final storage = Directory('/storage');
      if (await storage.exists()) {
        await for (final entity in storage.list(followLinks: false)) {
          final name = RemotePathUtil.basename(entity.path);
          if (entity is! Directory || name == 'emulated' || name == 'self') continue;
          candidates.add(BuiltinDirectory('SD 卡相册', '${entity.path}/DCIM'));
          candidates.add(BuiltinDirectory('SD 卡图片', '${entity.path}/Pictures'));
        }
      }
    } on FileSystemException {
      // 无权限读取 /storage 时忽略。
    }

    final result = <BuiltinDirectory>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      final normalized = candidate.path.replaceAll(RegExp(r'/+$'), '');
      if (seen.contains(normalized)) continue;
      seen.add(normalized);
      try {
        if (await Directory(normalized).exists()) result.add(candidate);
      } on FileSystemException {
        // 忽略不可访问目录。
      }
    }
    return result;
  }

  static Future<String> _storageRoot() async {
    final external = Directory('/storage/emulated/0');
    if (await external.exists()) return external.path;
    final env = Platform.environment['EXTERNAL_STORAGE'];
    if (env != null && env.isNotEmpty) return env;
    return '/sdcard';
  }

  /// 在后台 isolate 扫描目录，避免阻塞 UI。
  static Future<ScanOutcome> scan(
    String root, {
    int maxDepth = 8,
    int minBytes = 0,
    bool skipHidden = true,
    int limit = 200000,
  }) async {
    try {
      return await Isolate.run(
        () => scanSync(
          root: root,
          maxDepth: maxDepth,
          minBytes: minBytes,
          skipHidden: skipHidden,
          limit: limit,
        ),
      );
    } on IsolateSpawnException {
      return scanSync(
        root: root,
        maxDepth: maxDepth,
        minBytes: minBytes,
        skipHidden: skipHidden,
        limit: limit,
      );
    }
  }

  static ScanOutcome scanSync({
    required String root,
    int maxDepth = 8,
    int minBytes = 0,
    bool skipHidden = true,
    int limit = 200000,
  }) {
    final directory = Directory(root);
    if (!directory.existsSync()) {
      return const ScanOutcome(files: [], skipped: 0, errors: 1, truncated: false);
    }
    final files = <MediaFile>[];
    var skipped = 0;
    var errors = 0;
    var truncated = false;

    void walk(Directory dir, int depth) {
      if (files.length >= limit) {
        truncated = true;
        return;
      }
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        errors++;
        return;
      }
      for (final entity in entries) {
        if (files.length >= limit) {
          truncated = true;
          return;
        }
        final name = RemotePathUtil.basename(entity.path);
        if (skipHidden && name.startsWith('.')) continue;
        final lowerName = name.toLowerCase();
        if (entity is Directory) {
          if (depth >= maxDepth) continue;
          if (_skipDirectoryNames.contains(lowerName)) continue;
          walk(entity, depth + 1);
        } else if (entity is File) {
          final dot = lowerName.lastIndexOf('.');
          if (dot <= 0 || !imageExtensions.contains(lowerName.substring(dot + 1))) continue;
          try {
            final stat = entity.statSync();
            final size = stat.size;
            if (size < minBytes) {
              skipped++;
              continue;
            }
            files.add(MediaFile(
              path: entity.path,
              name: name,
              size: size,
              modifiedMs: stat.modified.millisecondsSinceEpoch,
            ));
          } on FileSystemException {
            errors++;
          }
        }
      }
    }

    walk(directory, 0);
    files.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    return ScanOutcome(
      files: files,
      skipped: skipped,
      errors: errors,
      truncated: truncated,
    );
  }
}
