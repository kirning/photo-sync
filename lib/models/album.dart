import 'package:flutter/foundation.dart';

enum AlbumSource { builtin, manual }

/// 一个相册 = 一个本地目录。
@immutable
class Album {
  const Album({
    required this.id,
    required this.name,
    required this.path,
    required this.source,
    required this.addedAt,
    this.enabled = true,
    this.lastScanAt,
    this.photoCount = 0,
    this.uploadedCount = 0,
    this.coverPath,
  });

  final String id;
  final String name;
  final String path;
  final AlbumSource source;
  final bool enabled;
  final DateTime addedAt;
  final DateTime? lastScanAt;
  final int photoCount;
  final int uploadedCount;
  final String? coverPath;

  Album copyWith({
    String? name,
    String? path,
    AlbumSource? source,
    bool? enabled,
    DateTime? lastScanAt,
    int? photoCount,
    int? uploadedCount,
    String? coverPath,
    bool clearCover = false,
  }) {
    return Album(
      id: id,
      name: name ?? this.name,
      path: path ?? this.path,
      source: source ?? this.source,
      enabled: enabled ?? this.enabled,
      addedAt: addedAt,
      lastScanAt: lastScanAt ?? this.lastScanAt,
      photoCount: photoCount ?? this.photoCount,
      uploadedCount: uploadedCount ?? this.uploadedCount,
      coverPath: clearCover ? null : (coverPath ?? this.coverPath),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'source': source.name,
        'enabled': enabled,
        'addedAt': addedAt.toIso8601String(),
        'lastScanAt': lastScanAt?.toIso8601String(),
        'photoCount': photoCount,
        'uploadedCount': uploadedCount,
        'coverPath': coverPath,
      };

  static Album fromJson(Map<String, dynamic> json) => Album(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        path: '${json['path'] ?? ''}',
        source: AlbumSource.values.firstWhere(
          (e) => e.name == json['source'],
          orElse: () => AlbumSource.manual,
        ),
        enabled: json['enabled'] as bool? ?? true,
        addedAt: DateTime.tryParse('${json['addedAt']}') ?? DateTime.now(),
        lastScanAt: DateTime.tryParse('${json['lastScanAt']}'),
        photoCount: (json['photoCount'] as num?)?.toInt() ?? 0,
        uploadedCount: (json['uploadedCount'] as num?)?.toInt() ?? 0,
        coverPath: json['coverPath'] as String?,
      );
}

/// 扫描得到的本地照片（不可变，可安全跨 isolate 传递）。
@immutable
class MediaFile {
  const MediaFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedMs,
  });

  final String path;
  final String name;
  final int size;
  final int modifiedMs;

  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(modifiedMs);

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'size': size,
        'modifiedMs': modifiedMs,
      };

  static MediaFile fromJson(Map<String, dynamic> json) => MediaFile(
        path: '${json['path']}',
        name: '${json['name']}',
        size: (json['size'] as num?)?.toInt() ?? 0,
        modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
      );
}

@immutable
class ScanOutcome {
  const ScanOutcome({
    required this.files,
    required this.skipped,
    required this.errors,
    required this.truncated,
  });

  final List<MediaFile> files;
  final int skipped;
  final int errors;
  final bool truncated;

  static const ScanOutcome empty =
      ScanOutcome(files: [], skipped: 0, errors: 0, truncated: false);
}
