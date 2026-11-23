import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../core/permissions.dart';
import '../data/app_paths.dart';
import '../data/app_repository.dart';
import '../models/album.dart';
import '../models/settings.dart';
import '../models/storage_config.dart';
import '../models/upload_job.dart';
import '../remote/remote_storages.dart';
import '../services/background_service.dart';
import '../services/media_scanner.dart';

class UploadStartResult {
  const UploadStartResult({
    this.job,
    this.queued = 0,
    this.skipped = 0,
    this.error,
  });

  final UploadJob? job;
  final int queued;
  final int skipped;
  final String? error;

  bool get started => job != null && queued > 0;
}

/// 全局状态：相册扫描结果、存储配置、任务进度、网络状态。
class AppState extends ChangeNotifier {
  AppState({
    required this.paths,
    required this.repo,
    UploadBackgroundService? service,
  }) : service = service ?? UploadBackgroundService.instance;

  final AppPaths paths;
  final AppRepository repo;
  final UploadBackgroundService service;

  bool ready = false;
  String? fatalError;
  MediaAccess mediaAccess = MediaAccess.granted;

  final Map<String, List<MediaFile>> _albumFiles = {};
  final Map<String, ScanOutcome> _scanOutcomes = {};
  final Set<String> _scanning = {};
  final Set<String> _testingStorage = {};

  List<ConnectivityResult> _connectivity = const [ConnectivityResult.none];

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _ticker;
  bool _refreshingJobs = false;

  List<Album> get albums => repo.albums;
  List<StorageConfig> get storages => repo.storages;
  List<UploadJob> get jobs => repo.jobs;
  AppSettings get settings => repo.settings;

  List<MediaFile> filesFor(String albumId) => _albumFiles[albumId] ?? const [];
  ScanOutcome? outcomeFor(String albumId) => _scanOutcomes[albumId];
  bool isScanning(String albumId) => _scanning.contains(albumId);
  bool isTestingStorage(String id) => _testingStorage.contains(id);

  List<UploadJob> get activeJobs =>
      jobs.where((job) => job.state.isActive || job.state == JobState.queued).toList();

  int uploadCountFor(String storageId) => repo.uploadsFor(storageId).length;

  bool isUploaded(String path) => repo.storageIdsFor(path).isNotEmpty;

  Set<String> uploadedStoragesFor(String path) => repo.storageIdsFor(path);

  Album? albumById(String id) {
    for (final album in albums) {
      if (album.id == id) return album;
    }
    return null;
  }

  StorageConfig? storageById(String id) {
    for (final storage in storages) {
      if (storage.id == id) return storage;
    }
    return null;
  }

  List<UploadedRecord> uploadsOf(String storageId) {
    final records = repo.uploadsFor(storageId).values.toList();
    records.sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
    return records;
  }

  /// 某张照片在指定存储上的上传记录（没有则返回 null）。
  UploadedRecord? uploadedRecord(String path, String storageId) =>
      repo.uploadedAt(storageId, path);

  // ---------------------------------------------------------------- 网络状态

  bool get onWifi =>
      _connectivity.contains(ConnectivityResult.wifi) ||
      _connectivity.contains(ConnectivityResult.ethernet);

  bool get onMobile => _connectivity.contains(ConnectivityResult.mobile);

  bool get offline => _connectivity.every((e) => e == ConnectivityResult.none);

  String get networkLabel {
    if (offline) return '无网络';
    if (_connectivity.contains(ConnectivityResult.wifi)) return 'Wi-Fi';
    if (_connectivity.contains(ConnectivityResult.ethernet)) return '有线网络';
    if (onMobile) return '移动数据';
    if (_connectivity.contains(ConnectivityResult.vpn)) return 'VPN';
    return '未知网络';
  }

  /// 当前网络是否满足“仅 Wi-Fi 上传”的限制。
  bool get networkAllowsUpload =>
      settings.networkPolicy == NetworkPolicy.any || onWifi;

  // ---------------------------------------------------------------- 初始化

  Future<void> init() async {
    try {
      await repo.load();
      mediaAccess = await ensureMediaAccess();
      unawaited(requestNotificationPermission());
      try {
        _connectivity = await Connectivity().checkConnectivity();
      } catch (_) {
        _connectivity = const [ConnectivityResult.none];
      }
      _connectivitySub = Connectivity().onConnectivityChanged.listen((value) {
        _connectivity = value;
        notifyListeners();
      });

      if (repo.albums.isEmpty) {
        await importBuiltinAlbums();
      }
      ready = true;
      notifyListeners();

      _ticker = Timer.periodic(const Duration(seconds: 2), (_) => refreshJobs());
      unawaited(refreshJobs());
      if (settings.autoScanOnStart) unawaited(scanAll());
    } catch (error, stack) {
      fatalError = '初始化失败：$error';
      AppLog.instance.error('state', fatalError!, stack);
      ready = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------- 相册

  /// 扫描系统常见目录并补充为相册，返回新增数量。
  Future<int> importBuiltinAlbums() async {
    final found = await MediaScanner.discoverCommon();
    var added = 0;
    for (final directory in found) {
      final exists = albums.any((album) => album.path == directory.path);
      if (exists) continue;
      await repo.addAlbum(
        name: directory.name,
        path: directory.path,
        source: AlbumSource.builtin,
      );
      added++;
    }
    if (added > 0) {
      AppLog.instance.info('albums', '导入 $added 个系统相册目录');
      notifyListeners();
    }
    return added;
  }

  Future<Album?> addManualAlbum(String directoryPath) async {
    final path = directoryPath.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty) return null;
    if (!await Directory(path).exists()) {
      throw const FileSystemException('目录不存在或无法访问');
    }
    final name = path.split('/').last;
    final album = await repo.addAlbum(name: name, path: path, source: AlbumSource.manual);
    notifyListeners();
    unawaited(scanAlbum(album));
    return album;
  }

  Future<void> removeAlbum(Album album) async {
    _albumFiles.remove(album.id);
    _scanOutcomes.remove(album.id);
    await repo.removeAlbum(album.id);
    notifyListeners();
  }

  Future<void> setAlbumEnabled(Album album, bool enabled) async {
    await repo.updateAlbum(album.copyWith(enabled: enabled));
    notifyListeners();
  }

  Future<void> scanAlbum(Album album) async {
    if (_scanning.contains(album.id)) return;
    _scanning.add(album.id);
    notifyListeners();
    try {
      final outcome = await MediaScanner.scan(
        album.path,
        minBytes: settings.minImageBytes,
        skipHidden: settings.skipHidden,
      );
      _albumFiles[album.id] = outcome.files;
      _scanOutcomes[album.id] = outcome;
      final uploadedCount =
          outcome.files.where((file) => isUploaded(file.path)).length;
      await repo.updateAlbum(album.copyWith(
        lastScanAt: DateTime.now(),
        photoCount: outcome.files.length,
        uploadedCount: uploadedCount,
        coverPath: outcome.files.isNotEmpty ? outcome.files.first.path : null,
      ));
      AppLog.instance.info(
        'scan',
        '扫描「${album.name}」完成：${outcome.files.length} 张照片'
        '${outcome.truncated ? '（已截断）' : ''}',
      );
    } catch (error) {
      AppLog.instance.error('scan', '扫描「${album.name}」失败：$error');
    } finally {
      _scanning.remove(album.id);
      notifyListeners();
    }
  }

  Future<void> scanAll() async {
    for (final album in List<Album>.from(albums)) {
      if (!album.enabled) continue;
      await scanAlbum(album);
    }
  }

  // ---------------------------------------------------------------- 存储

  Future<void> saveStorage(StorageConfig config) async {
    await repo.addStorage(config);
    notifyListeners();
  }

  Future<void> deleteStorage(StorageConfig config) async {
    await repo.removeStorage(config.id);
    notifyListeners();
  }

  /// 测试连接，结果写回配置并返回错误信息（null 表示成功）。
  Future<String?> testStorage(StorageConfig config) async {
    if (_testingStorage.contains(config.id)) return null;
    _testingStorage.add(config.id);
    notifyListeners();
    try {
      final error = await RemoteStorages.test(config);
      final tested = config.copyWith(
        lastTestAt: DateTime.now(),
        lastTestOk: error == null,
        lastTestMessage: error ?? '连接成功',
      );
      await repo.updateStorage(tested);
      AppLog.instance.info(
        'storage',
        error == null ? '「${config.name}」连接成功' : '「${config.name}」连接失败：$error',
      );
      return error;
    } finally {
      _testingStorage.remove(config.id);
      notifyListeners();
    }
  }

  /// 删除远端照片；返回错误信息，null 表示成功。
  Future<String?> deleteRemoteFile(StorageConfig config, UploadedRecord record) async {
    final storage = RemoteStorages.create(config);
    try {
      await storage.open();
      await storage.delete(record.remotePath);
      await repo.removeUpload(config.id, record.path);
      AppLog.instance.info('storage', '已删除远端文件：${record.remotePath}');
      notifyListeners();
      return null;
    } catch (error) {
      final message = error is Exception ? '$error' : '$error';
      AppLog.instance.error('storage', '删除远端文件失败：$message');
      return message;
    } finally {
      try {
        await storage.close();
      } catch (_) {
        // 忽略
      }
    }
  }

  // ---------------------------------------------------------------- 上传

  Future<UploadStartResult> startUpload({
    required StorageConfig storage,
    required String albumName,
    required List<MediaFile> files,
  }) async {
    if (!storage.enabled) {
      return const UploadStartResult(error: '该存储服务已停用');
    }
    final pending = <MediaFile>[];
    var skipped = 0;
    for (final file in files) {
      if (repo.uploadedAt(storage.id, file.path) != null) {
        skipped++;
        continue;
      }
      if (!await File(file.path).exists()) continue;
      pending.add(file);
    }
    if (pending.isEmpty) {
      return UploadStartResult(
        skipped: skipped,
        error: skipped > 0 ? '所选照片都已上传到「${storage.name}」' : '没有可上传的照片',
      );
    }

    final items = pending.map((file) => JobItem.fromMedia(albumName, file)).toList();
    final job = await repo.createJob(
      storageId: storage.id,
      storageName: storage.name,
      albumNames: [albumName],
      items: items,
      wifiOnly: settings.networkPolicy == NetworkPolicy.wifiOnly,
    );
    final spec = UploadJobSpec(
      id: job.id,
      storage: storage,
      items: items,
      wifiOnly: job.wifiOnly,
      folderTemplate: settings.folderTemplate,
      concurrency: settings.concurrency,
    );
    try {
      await service.enqueue(spec, paths);
    } catch (error) {
      job.state = JobState.failed;
      job.message = '启动后台上传失败：$error';
      await repo.saveJobs();
      notifyListeners();
      return UploadStartResult(error: job.message);
    }
    job.startedAt = DateTime.now();
    job.state = JobState.running;
    await repo.saveJobs();
    AppLog.instance.info('upload', '任务「${job.id}」开始上传 ${items.length} 个文件');
    notifyListeners();
    return UploadStartResult(job: job, queued: items.length, skipped: skipped);
  }

  Future<void> pauseJob(UploadJob job) async {
    await service.pause(job.id);
    job.state = JobState.paused;
    await repo.saveJobs();
    notifyListeners();
  }

  Future<void> resumeJob(UploadJob job) async {
    await service.resume(job.id);
    job.state = JobState.running;
    await repo.saveJobs();
    notifyListeners();
  }

  Future<void> cancelJob(UploadJob job) async {
    await service.cancel(job.id);
    job.state = JobState.cancelled;
    await repo.saveJobs();
    notifyListeners();
  }

  Future<void> removeJob(UploadJob job) async {
    await cancelAndRemoveJob(job.id, paths);
    await repo.removeJob(job.id);
    notifyListeners();
  }

  Future<void> clearFinishedJobs() async {
    for (final job in jobs.where((e) => e.state.isFinished).toList()) {
      await cancelAndRemoveJob(job.id, paths);
    }
    await repo.clearFinishedJobs();
    notifyListeners();
  }

  UploadJob? jobById(String id) {
    for (final job in jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  Future<void> refreshJobs() async {
    if (_refreshingJobs) return;    _refreshingJobs = true;
    var changed = false;
    try {
      for (final job in List<UploadJob>.from(jobs)) {
        if (job.state.isFinished) continue;
        final before = '${job.state.name}-${job.processed}-${job.doneBytes}';
        final status = await repo.syncJobFromDisk(job);
        if (status == null) continue;
        final after = '${job.state.name}-${job.processed}-${job.doneBytes}';
        if (before != after) changed = true;
      }
      if (changed) {
        for (final album in albums) {
          final files = _albumFiles[album.id];
          if (files == null) continue;
          final count = files.where((file) => isUploaded(file.path)).length;
          if (count != album.uploadedCount) {
            await repo.updateAlbum(album.copyWith(uploadedCount: count));
          }
        }
      }
    } finally {
      _refreshingJobs = false;
      if (changed) notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 设置

  Future<void> saveSettings(AppSettings value) async {
    repo.settings = value;
    await repo.saveSettings();
    notifyListeners();
  }

  Future<void> resetUploadIndex([String? storageId]) async {
    await repo.clearUploads(storageId);
    for (final album in List<Album>.from(albums)) {
      final files = _albumFiles[album.id];
      final count = files == null
          ? 0
          : files.where((file) => isUploaded(file.path)).length;
      await repo.updateAlbum(album.copyWith(uploadedCount: count));
    }
    notifyListeners();
  }
}
