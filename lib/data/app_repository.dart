import 'dart:convert';
import 'dart:io';

import '../core/app_log.dart';
import '../core/json_file.dart';
import '../models/album.dart';
import '../models/settings.dart';
import '../models/storage_config.dart';
import '../models/upload_job.dart';
import 'app_paths.dart';

/// 本地数据仓库：全部落盘为 JSON，方便后台 isolate 直接读写。
class AppRepository {
  AppRepository(this.paths);

  final AppPaths paths;

  final List<Album> albums = [];
  final List<StorageConfig> storages = [];
  final List<UploadJob> jobs = [];
  AppSettings settings = AppSettings();

  final Map<String, Map<String, UploadedRecord>> _uploadIndex = {};

  List<UploadedRecord> get allUploads =>
      _uploadIndex.values.expand((e) => e.values).toList(growable: false);

  Map<String, UploadedRecord> uploadsFor(String storageId) =>
      _uploadIndex[storageId] ?? const {};

  UploadedRecord? uploadedAt(String storageId, String path) =>
      _uploadIndex[storageId]?[path];

  /// 这个本地文件在哪些存储上已经上传过。
  Set<String> storageIdsFor(String path) {
    final result = <String>{};
    _uploadIndex.forEach((storageId, records) {
      if (records.containsKey(path)) result.add(storageId);
    });
    return result;
  }

  Future<void> load() async {
    await paths.ensureDirectories();
    await _loadAlbums();
    await _loadStorages();
    await _loadSettings();
    await _loadJobs();
    await _loadUploads();
    _pruneJobs();
    AppLog.instance.info('store', '加载完成：${albums.length} 个相册、'
        '${storages.length} 个存储、${jobs.length} 个任务');
  }

  Future<void> _loadAlbums() async {
    final list = await JsonFile(paths.albumsFile).readList();
    albums.clear();
    for (final item in list ?? const []) {
      if (item is Map) albums.add(Album.fromJson(item.cast<String, dynamic>()));
    }
  }

  Future<void> _loadStorages() async {
    final list = await JsonFile(paths.storagesFile).readList();
    storages.clear();
    for (final item in list ?? const []) {
      if (item is Map) storages.add(StorageConfig.fromJson(item.cast<String, dynamic>()));
    }
  }

  Future<void> _loadSettings() async {
    final json = await JsonFile(paths.settingsFile).readObject();
    settings = json == null ? AppSettings() : AppSettings.fromJson(json);
  }

  Future<void> _loadJobs() async {
    final list = await JsonFile(paths.jobsIndexFile).readList();
    jobs.clear();
    for (final item in list ?? const []) {
      if (item is Map) jobs.add(UploadJob.fromJson(item.cast<String, dynamic>()));
    }
  }

  Future<void> _loadUploads() async {
    _uploadIndex.clear();
    if (!await paths.uploadsDir.exists()) return;
    await for (final entity in paths.uploadsDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final json = await JsonFile(entity).readObject();
      final records = <String, UploadedRecord>{};
      final raw = json?['records'];
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is Map) {
            final record = UploadedRecord.fromJson(value.cast<String, dynamic>());
            records['$key'] = record;
          }
        });
      }
      final storageId = '${json?['storageId'] ?? ''}';
      if (storageId.isNotEmpty) _uploadIndex[storageId] = records;
    }
  }

  Future<void> saveAlbums() =>
      JsonFile(paths.albumsFile).writeAtomic(albums.map((e) => e.toJson()).toList());

  Future<void> saveStorages() =>
      JsonFile(paths.storagesFile).writeAtomic(storages.map((e) => e.toJson()).toList());

  Future<void> saveSettings() => JsonFile(paths.settingsFile).writeAtomic(settings.toJson());

  Future<void> saveJobs() {
    _pruneJobs();
    return JsonFile(paths.jobsIndexFile)
        .writeAtomic(jobs.map((e) => e.toJson()).toList());
  }

  void _pruneJobs() {
    if (jobs.length <= 60) return;
    jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    jobs.removeRange(60, jobs.length);
  }

  Future<Album> addAlbum({
    required String name,
    required String path,
    AlbumSource source = AlbumSource.manual,
  }) async {
    final normalized = path.replaceAll(RegExp(r'/+$'), '');
    final existing = albums.where((e) => e.path == normalized).toList();
    if (existing.isNotEmpty) return existing.first;
    final album = Album(
      id: _newId(),
      name: name.trim().isEmpty ? normalized.split('/').last : name.trim(),
      path: normalized,
      source: source,
      addedAt: DateTime.now(),
    );
    albums.add(album);
    await saveAlbums();
    return album;
  }

  Future<void> updateAlbum(Album album) async {
    final index = albums.indexWhere((e) => e.id == album.id);
    if (index < 0) return;
    albums[index] = album;
    await saveAlbums();
  }

  Future<void> removeAlbum(String id) async {
    albums.removeWhere((e) => e.id == id);
    await saveAlbums();
  }

  Future<void> addStorage(StorageConfig config) async {
    storages.removeWhere((e) => e.id == config.id);
    storages.add(config);
    await saveStorages();
  }

  Future<void> updateStorage(StorageConfig config) => addStorage(config);

  Future<void> removeStorage(String id) async {
    storages.removeWhere((e) => e.id == id);
    _uploadIndex.remove(id);
    await saveStorages();
    final file = paths.uploadsFile(id);
    if (await file.exists()) await file.delete();
  }

  Future<void> recordUpload(UploadedRecord record) async {
    final map = _uploadIndex.putIfAbsent(record.storageId, () => {});
    map[record.path] = record;
    await _saveUploadIndex(record.storageId);
  }

  Future<void> recordUploads(String storageId, Iterable<UploadedRecord> records) async {
    final map = _uploadIndex.putIfAbsent(storageId, () => {});
    for (final record in records) {
      map[record.path] = record;
    }
    await _saveUploadIndex(storageId);
  }

  Future<void> removeUpload(String storageId, String path) async {
    final map = _uploadIndex[storageId];
    if (map == null) return;
    map.remove(path);
    await _saveUploadIndex(storageId);
  }

  Future<void> clearUploads([String? storageId]) async {
    if (storageId == null) {
      _uploadIndex.clear();
      if (await paths.uploadsDir.exists()) {
        await for (final entity in paths.uploadsDir.list()) {
          if (entity is File) await entity.delete();
        }
      }
      return;
    }
    _uploadIndex[storageId] = {};
    await _saveUploadIndex(storageId);
  }

  Future<void> _saveUploadIndex(String storageId) async {
    final map = _uploadIndex[storageId] ?? {};
    await JsonFile(paths.uploadsFile(storageId)).writeAtomic({
      'version': 1,
      'storageId': storageId,
      'savedAt': DateTime.now().toIso8601String(),
      'records': map.map((key, value) => MapEntry(key, value.toJson())),
    });
  }

  Future<UploadJob?> jobById(String id) async {
    for (final job in jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  Future<UploadJob> createJob({
    required String storageId,
    required String storageName,
    required List<String> albumNames,
    required List<JobItem> items,
    required bool wifiOnly,
  }) async {
    final job = UploadJob(
      id: _newId(),
      storageId: storageId,
      storageName: storageName,
      albumNames: albumNames,
      totalItems: items.length,
      totalBytes: items.fold(0, (sum, item) => sum + item.size),
      wifiOnly: wifiOnly,
      createdAt: DateTime.now(),
    );
    jobs.insert(0, job);
    await saveJobs();
    AppLog.instance.info('job', '创建任务 ${job.id}：${items.length} 个文件');
    return job;
  }

  Future<void> removeJob(String id) async {
    jobs.removeWhere((e) => e.id == id);
    await saveJobs();
    for (final file in [
      paths.jobSpecFile(id),
      paths.jobStatusFile(id),
      paths.jobResultsFile(id),
    ]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> clearFinishedJobs() async {
    final finished = jobs.where((e) => e.state.isFinished).map((e) => e.id).toList();
    for (final id in finished) {
      await removeJob(id);
    }
  }

  /// 把后台任务的结果合并进“已上传”索引。
  Future<JobStatus?> syncJobFromDisk(UploadJob job) async {
    final statusJson = await JsonFile(paths.jobStatusFile(job.id)).readObject();
    if (statusJson == null) return null;
    final status = JobStatus.fromJson(statusJson);
    job.applyStatus(status);
    if (status.state.isFinished || status.done + status.failed + status.skipped > 0) {
      await _mergeResults(job);
    }
    await saveJobs();
    return status;
  }

  Future<List<JobResult>> readResults(String jobId) async {
    final file = paths.jobResultsFile(jobId);
    if (!await file.exists()) return [];
    final results = <JobResult>[];
    try {
      final lines = await file.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line);
          if (json is Map<String, dynamic>) results.add(JobResult.fromJson(json));
        } on FormatException {
          // 忽略损坏的行（例如进程被杀时写了半行）。
        }
      }
    } on FileSystemException {
      return results;
    }
    return results;
  }

  Future<void> _mergeResults(UploadJob job) async {
    final results = await readResults(job.id);
    if (results.isEmpty) return;
    final records = <String, UploadedRecord>{};
    for (final result in results) {
      if (!result.success || result.remotePath == null) continue;
      records[result.path] = UploadedRecord(
        path: result.path,
        storageId: job.storageId,
        remotePath: result.remotePath!,
        size: result.size,
        modifiedMs: result.modifiedMs,
        uploadedAt: DateTime.now(),
        jobId: job.id,
      );
    }
    if (records.isNotEmpty) {
      await recordUploads(job.storageId, records.values);
    }
  }

  static String _newId() {
    final now = DateTime.now();
    final random = now.microsecondsSinceEpoch.toRadixString(36);
    return '${now.millisecondsSinceEpoch.toRadixString(36)}_$random';
  }

  /// 供 UI 统计相册已上传数量。
  int uploadedCountForAlbum(Album album, Iterable<MediaFile>? files) {
    if (files == null) return album.uploadedCount;
    var count = 0;
    for (final file in files) {
      if (storageIdsFor(file.path).isNotEmpty) count++;
    }
    return count;
  }
}
