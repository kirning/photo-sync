import 'package:flutter/material.dart';

enum StorageType { webdav, smb, s3 }

extension StorageTypeX on StorageType {
  String get label => switch (this) {
        StorageType.webdav => 'WebDAV',
        StorageType.smb => 'SMB',
        StorageType.s3 => 'S3',
      };

  String get description => switch (this) {
        StorageType.webdav => '群晖、坚果云、Nextcloud 等 WebDAV 服务',
        StorageType.smb => '局域网 NAS / Windows 共享文件夹（SMB2/3）',
        StorageType.s3 => 'AWS S3、MinIO、阿里云 OSS(S3 兼容) 等对象存储',
      };

  IconData get icon => switch (this) {
        StorageType.webdav => Icons.cloud_outlined,
        StorageType.smb => Icons.dns_outlined,
        StorageType.s3 => Icons.inventory_2_outlined,
      };
}

/// 存储服务的连接配置。
///
/// 不同 [type] 使用不同的字段集合，统一放在 [fields] 里并按键读取，
/// 这样新增字段不需要改动数据库结构。
class StorageConfig {
  StorageConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.fields,
    required this.createdAt,
    this.enabled = true,
    this.lastTestAt,
    this.lastTestOk,
    this.lastTestMessage,
  });

  final String id;
  final String name;
  final StorageType type;
  final Map<String, dynamic> fields;
  final bool enabled;
  final DateTime createdAt;
  final DateTime? lastTestAt;
  final bool? lastTestOk;
  final String? lastTestMessage;

  String field(String key, [String fallback = '']) {
    final value = fields[key];
    if (value == null) return fallback;
    return '$value';
  }

  bool boolField(String key, [bool fallback = false]) {
    final value = fields[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = '$value'.toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
    return fallback;
  }

  StorageConfig copyWith({
    String? name,
    StorageType? type,
    Map<String, dynamic>? fields,
    bool? enabled,
    DateTime? lastTestAt,
    bool? lastTestOk,
    String? lastTestMessage,
    bool clearTest = false,
  }) {
    return StorageConfig(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      fields: fields ?? this.fields,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
      lastTestAt: clearTest ? null : (lastTestAt ?? this.lastTestAt),
      lastTestOk: clearTest ? null : (lastTestOk ?? this.lastTestOk),
      lastTestMessage: clearTest ? null : (lastTestMessage ?? this.lastTestMessage),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'fields': fields,
        'enabled': enabled,
        'createdAt': createdAt.toIso8601String(),
        'lastTestAt': lastTestAt?.toIso8601String(),
        'lastTestOk': lastTestOk,
        'lastTestMessage': lastTestMessage,
      };

  static StorageConfig fromJson(Map<String, dynamic> json) => StorageConfig(
        id: '${json['id']}',
        name: '${json['name'] ?? ''}',
        type: StorageType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => StorageType.webdav,
        ),
        fields: (json['fields'] as Map?)?.cast<String, dynamic>() ?? const {},
        enabled: json['enabled'] as bool? ?? true,
        createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
        lastTestAt: DateTime.tryParse('${json['lastTestAt']}'),
        lastTestOk: json['lastTestOk'] as bool?,
        lastTestMessage: json['lastTestMessage'] as String?,
      );
}

/// 已上传记录：以本地文件路径为键做“已备份”标识。
class UploadedRecord {
  UploadedRecord({
    required this.path,
    required this.storageId,
    required this.remotePath,
    required this.size,
    required this.modifiedMs,
    required this.uploadedAt,
    this.jobId,
    this.contentHash,
  });

  final String path;
  final String storageId;
  final String remotePath;
  final int size;
  final int modifiedMs;
  final DateTime uploadedAt;
  final String? jobId;

  /// 文件内容的 SHA-256（旧版本的记录可能没有）。
  ///
  /// 有它就可以跨路径判断「同一张照片是不是已经传过」。
  final String? contentHash;

  String get key => '$storageId|$path';

  Map<String, dynamic> toJson() => {
        'path': path,
        'storageId': storageId,
        'remotePath': remotePath,
        'size': size,
        'modifiedMs': modifiedMs,
        'uploadedAt': uploadedAt.toIso8601String(),
        'jobId': jobId,
        'hash': contentHash,
      };

  static UploadedRecord fromJson(Map<String, dynamic> json) => UploadedRecord(
        path: '${json['path']}',
        storageId: '${json['storageId']}',
        remotePath: '${json['remotePath']}',
        size: (json['size'] as num?)?.toInt() ?? 0,
        modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
        uploadedAt: DateTime.tryParse('${json['uploadedAt']}') ?? DateTime.now(),
        jobId: json['jobId'] as String?,
        contentHash: json['hash'] as String?,
      );
}
