import 'package:flutter/material.dart';

import 'album.dart';
import 'storage_config.dart';

enum JobState { queued, running, paused, completed, failed, cancelled }

extension JobStateX on JobState {
  bool get isFinished =>
      this == JobState.completed || this == JobState.failed || this == JobState.cancelled;

  bool get isActive => this == JobState.running || this == JobState.paused;

  String get label => switch (this) {
        JobState.queued => '等待中',
        JobState.running => '上传中',
        JobState.paused => '已暂停',
        JobState.completed => '已完成',
        JobState.failed => '失败',
        JobState.cancelled => '已取消',
      };

  Color color(ColorScheme scheme) => switch (this) {
        JobState.queued => scheme.tertiary,
        JobState.running => scheme.primary,
        JobState.paused => scheme.secondary,
        JobState.completed => const Color(0xFF2E7D32),
        JobState.failed => scheme.error,
        JobState.cancelled => scheme.outline,
      };

  IconData get icon => switch (this) {
        JobState.queued => Icons.schedule,
        JobState.running => Icons.sync,
        JobState.paused => Icons.pause_circle_outline,
        JobState.completed => Icons.check_circle,
        JobState.failed => Icons.error_outline,
        JobState.cancelled => Icons.cancel_outlined,
      };
}

/// 单个待上传文件。
@immutable
class JobItem {
  const JobItem({
    required this.path,
    required this.name,
    required this.albumName,
    required this.size,
    required this.modifiedMs,
  });

  final String path;
  final String name;
  final String albumName;
  final int size;
  final int modifiedMs;

  factory JobItem.fromMedia(String albumName, MediaFile file) => JobItem(
        path: file.path,
        name: file.name,
        albumName: albumName,
        size: file.size,
        modifiedMs: file.modifiedMs,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'album': albumName,
        'size': size,
        'modifiedMs': modifiedMs,
      };

  static JobItem fromJson(Map<String, dynamic> json) => JobItem(
        path: '${json['path']}',
        name: '${json['name']}',
        albumName: '${json['album'] ?? ''}',
        size: (json['size'] as num?)?.toInt() ?? 0,
        modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
      );
}

/// 后台 isolate 读取的任务描述（不可变，整份写入磁盘）。
class UploadJobSpec {
  const UploadJobSpec({
    required this.id,
    required this.storage,
    required this.items,
    required this.wifiOnly,
    required this.folderTemplate,
    required this.concurrency,
    this.existingRemotePaths = const {},
    this.existingHashes = const {},
  });

  final String id;
  final StorageConfig storage;
  final List<JobItem> items;
  final bool wifiOnly;
  final String folderTemplate;
  final int concurrency;

  /// 已经上传过的本地路径 -> 远端路径，用于跳过重复文件。
  final Map<String, String> existingRemotePaths;

  /// 已经上传过的内容哈希 -> 远端路径，用于跨路径去重（同一张照片换个目录就不再传）。
  final Map<String, String> existingHashes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'storage': storage.toJson(),
        'items': items.map((e) => e.toJson()).toList(),
        'wifiOnly': wifiOnly,
        'folderTemplate': folderTemplate,
        'concurrency': concurrency,
        'existing': existingRemotePaths,
        'hashes': existingHashes,
      };

  static UploadJobSpec fromJson(Map<String, dynamic> json) => UploadJobSpec(
        id: '${json['id']}',
        storage: StorageConfig.fromJson(
          (json['storage'] as Map).cast<String, dynamic>(),
        ),
        items: (json['items'] as List? ?? const [])
            .map((e) => JobItem.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        wifiOnly: json['wifiOnly'] as bool? ?? true,
        folderTemplate: '${json['folderTemplate'] ?? ''}',
        concurrency: (json['concurrency'] as num?)?.toInt() ?? 2,
        existingRemotePaths:
            (json['existing'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
        existingHashes:
            (json['hashes'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
      );
}

/// 进度快照：后台 isolate 持续写入，UI 轮询显示。
class JobStatus {
  const JobStatus({
    required this.state,
    required this.done,
    required this.failed,
    required this.skipped,
    required this.total,
    required this.doneBytes,
    required this.totalBytes,
    this.currentName,
    this.message,
    this.speed = 0,
    this.updatedAt,
  });

  const JobStatus.initial()
      : state = JobState.queued,
        done = 0,
        failed = 0,
        skipped = 0,
        total = 0,
        doneBytes = 0,
        totalBytes = 0,
        currentName = null,
        message = null,
        speed = 0,
        updatedAt = null;

  final JobState state;
  final int done;
  final int failed;
  final int skipped;
  final int total;
  final int doneBytes;
  final int totalBytes;
  final String? currentName;
  final String? message;
  final double speed;
  final DateTime? updatedAt;

  int get processed => done + failed + skipped;

  double get progress => total <= 0 ? 0 : processed / total;

  double get byteProgress => totalBytes <= 0 ? 0 : doneBytes / totalBytes;

  JobStatus copyWith({
    JobState? state,
    int? done,
    int? failed,
    int? skipped,
    int? total,
    int? doneBytes,
    int? totalBytes,
    String? currentName,
    String? message,
    double? speed,
    DateTime? updatedAt,
    bool clearCurrent = false,
  }) {
    return JobStatus(
      state: state ?? this.state,
      done: done ?? this.done,
      failed: failed ?? this.failed,
      skipped: skipped ?? this.skipped,
      total: total ?? this.total,
      doneBytes: doneBytes ?? this.doneBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      currentName: clearCurrent ? null : (currentName ?? this.currentName),
      message: message ?? this.message,
      speed: speed ?? this.speed,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'state': state.name,
        'done': done,
        'failed': failed,
        'skipped': skipped,
        'total': total,
        'doneBytes': doneBytes,
        'totalBytes': totalBytes,
        'currentName': currentName,
        'message': message,
        'speed': speed,
        'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
      };

  static JobStatus fromJson(Map<String, dynamic> json) => JobStatus(
        state: JobState.values.firstWhere(
          (e) => e.name == json['state'],
          orElse: () => JobState.queued,
        ),
        done: (json['done'] as num?)?.toInt() ?? 0,
        failed: (json['failed'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        doneBytes: (json['doneBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        currentName: json['currentName'] as String?,
        message: json['message'] as String?,
        speed: (json['speed'] as num?)?.toDouble() ?? 0,
        updatedAt: DateTime.tryParse('${json['updatedAt']}'),
      );
}

/// 每个文件的处理结果，追加写入 results.jsonl。
class JobResult {
  const JobResult({
    required this.path,
    required this.name,
    required this.albumName,
    required this.size,
    required this.modifiedMs,
    required this.status,
    this.remotePath,
    this.error,
    this.hash,
  });

  final String path;
  final String name;
  final String albumName;
  final int size;
  final int modifiedMs;
  final String status; // uploaded / skipped / failed
  final String? remotePath;
  final String? error;

  /// 文件内容 SHA-256（用于下次按内容去重）。
  final String? hash;

  bool get success => status == 'uploaded' || status == 'skipped';

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'album': albumName,
        'size': size,
        'modifiedMs': modifiedMs,
        'status': status,
        'remotePath': remotePath,
        'error': error,
        'hash': hash,
        'at': DateTime.now().toIso8601String(),
      };

  static JobResult fromJson(Map<String, dynamic> json) => JobResult(
        path: '${json['path']}',
        name: '${json['name'] ?? ''}',
        albumName: '${json['album'] ?? ''}',
        size: (json['size'] as num?)?.toInt() ?? 0,
        modifiedMs: (json['modifiedMs'] as num?)?.toInt() ?? 0,
        status: '${json['status']}',
        remotePath: json['remotePath'] as String?,
        error: json['error'] as String?,
        hash: json['hash'] as String?,
      );
}

/// UI 侧展示的任务记录（不含文件清单）。
class UploadJob {
  UploadJob({
    required this.id,
    required this.storageId,
    required this.storageName,
    required this.albumNames,
    required this.totalItems,
    required this.totalBytes,
    required this.wifiOnly,
    required this.createdAt,
    this.state = JobState.queued,
    this.doneCount = 0,
    this.failedCount = 0,
    this.skippedCount = 0,
    this.doneBytes = 0,
    this.currentName,
    this.message,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String storageId;
  final String storageName;
  final List<String> albumNames;
  final int totalItems;
  final int totalBytes;
  final bool wifiOnly;
  final DateTime createdAt;
  JobState state;
  int doneCount;
  int failedCount;
  int skippedCount;
  int doneBytes;
  String? currentName;
  String? message;
  DateTime? startedAt;
  DateTime? finishedAt;

  int get processed => doneCount + failedCount + skippedCount;

  double get progress => totalItems <= 0 ? 0 : processed / totalItems;

  String get albumLabel => albumNames.isEmpty
      ? '未知相册'
      : albumNames.length == 1
          ? albumNames.first
          : '${albumNames.first} 等 ${albumNames.length} 个相册';

  void applyStatus(JobStatus status) {
    state = status.state;
    doneCount = status.done;
    failedCount = status.failed;
    skippedCount = status.skipped;
    doneBytes = status.doneBytes;
    currentName = status.currentName;
    message = status.message;
    if (status.state.isFinished) finishedAt ??= DateTime.now();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'storageId': storageId,
        'storageName': storageName,
        'albums': albumNames,
        'totalItems': totalItems,
        'totalBytes': totalBytes,
        'wifiOnly': wifiOnly,
        'createdAt': createdAt.toIso8601String(),
        'state': state.name,
        'done': doneCount,
        'failed': failedCount,
        'skipped': skippedCount,
        'doneBytes': doneBytes,
        'currentName': currentName,
        'message': message,
        'startedAt': startedAt?.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
      };

  static UploadJob fromJson(Map<String, dynamic> json) => UploadJob(
        id: '${json['id']}',
        storageId: '${json['storageId']}',
        storageName: '${json['storageName'] ?? ''}',
        albumNames: (json['albums'] as List? ?? const []).map((e) => '$e').toList(),
        totalItems: (json['totalItems'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        wifiOnly: json['wifiOnly'] as bool? ?? true,
        createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
        state: JobState.values.firstWhere(
          (e) => e.name == json['state'],
          orElse: () => JobState.queued,
        ),
        doneCount: (json['done'] as num?)?.toInt() ?? 0,
        failedCount: (json['failed'] as num?)?.toInt() ?? 0,
        skippedCount: (json['skipped'] as num?)?.toInt() ?? 0,
        doneBytes: (json['doneBytes'] as num?)?.toInt() ?? 0,
        currentName: json['currentName'] as String?,
        message: json['message'] as String?,
        startedAt: DateTime.tryParse('${json['startedAt']}'),
        finishedAt: DateTime.tryParse('${json['finishedAt']}'),
      );
}
