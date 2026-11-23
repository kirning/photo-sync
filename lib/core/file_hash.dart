import 'dart:io';

import 'package:crypto/crypto.dart';

import 'json_file.dart';

/// 文件内容哈希缓存：按「路径 + 大小 + 修改时间」缓存 SHA-256。
///
/// 用它判断「这张照片是不是已经传过」比按路径判断可靠得多：
/// 同一张照片可能同时出现在 DCIM、Pictures、微信目录里，
/// 复制过、改过名之后路径变了但内容没变，按内容哈希就能识别出来，避免重复上传。
///
/// 全部是纯 Dart（dart:io + crypto），后台 isolate 可直接使用。
class HashCache {
  HashCache(this.file);

  /// 缓存文件，通常是 `<应用目录>/hashes.json`。
  final File file;

  final Map<String, HashEntry> _entries = {};
  bool _dirty = false;
  int _pendingWrites = 0;

  /// 读取已有缓存；文件不存在或损坏时内部为空。
  Future<void> load() async {
    final json = await JsonFile(file).readObject();
    final raw = json?['entries'];
    if (raw is! Map) return;
    raw.forEach((key, value) {
      if (value is Map) {
        final entry = HashEntry.fromJson(value.cast<String, dynamic>());
        if (entry.hash.isNotEmpty) _entries['$key'] = entry;
      }
    });
  }

  /// 只查缓存，不读文件内容。
  String? cachedHash(String path, {required int size, required int modifiedMs}) {
    final entry = _entries[path];
    if (entry == null) return null;
    if (entry.size != size || entry.modifiedMs != modifiedMs) return null;
    return entry.hash;
  }

  /// 计算（或从缓存取）文件内容哈希。
  ///
  /// [size]、[modifiedMs] 已知时传进来可以少两次 stat。
  Future<String> hashOf(
    File file, {
    int? size,
    int? modifiedMs,
  }) async {
    final path = file.path;
    final length = size ?? await file.length();
    final mtime = modifiedMs ?? (await file.lastModified()).millisecondsSinceEpoch;
    final cached = cachedHash(path, size: length, modifiedMs: mtime);
    if (cached != null) return cached;

    final digest = await sha256.bind(file.openRead()).first;
    final hash = digest.toString();
    _entries[path] = HashEntry(size: length, modifiedMs: mtime, hash: hash);
    _dirty = true;
    await _saveIfNeeded();
    return hash;
  }

  /// 写回磁盘（每 20 次新计算落一次盘，任务结束时调用 `force: true`）。
  Future<void> save({bool force = true}) async {
    if (force) _pendingWrites = 0;
    await _saveIfNeeded(force: force);
  }

  Future<void> _saveIfNeeded({bool force = false}) async {
    if (!_dirty) return;
    _pendingWrites++;
    if (!force && _pendingWrites < 20) return;
    _pendingWrites = 0;
    _dirty = false;
    await JsonFile(file).writeAtomic({
      'version': 1,
      'entries': _entries.map((key, value) => MapEntry(key, value.toJson())),
    });
  }

  /// 移除缓存里已经不存在的路径，控制文件大小。
  void pruneMissing() {
    final keep = <String, HashEntry>{};
    _entries.forEach((path, entry) {
      if (File(path).existsSync()) keep[path] = entry;
    });
    if (keep.length == _entries.length) return;
    _entries
      ..clear()
      ..addAll(keep);
    _dirty = true;
  }

  int get length => _entries.length;
}

/// 一条哈希缓存记录。
class HashEntry {
  const HashEntry({
    required this.size,
    required this.modifiedMs,
    required this.hash,
  });

  final int size;
  final int modifiedMs;
  final String hash;

  Map<String, dynamic> toJson() => {
        'size': size,
        'mtime': modifiedMs,
        'hash': hash,
      };

  static HashEntry fromJson(Map<String, dynamic> json) => HashEntry(
        size: (json['size'] as num?)?.toInt() ?? 0,
        modifiedMs: (json['mtime'] as num?)?.toInt() ?? 0,
        hash: '${json['hash'] ?? ''}',
      );
}
