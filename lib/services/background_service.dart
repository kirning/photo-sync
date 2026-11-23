import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';

import '../core/crash_log.dart';
import '../core/json_file.dart';
import '../core/file_hash.dart';
import '../data/app_paths.dart';
import '../models/upload_job.dart';
import 'upload_runner.dart';

const String uploadNotificationChannelId = 'photo_sync_upload';
const int uploadNotificationId = 8801;

/// 在 `main()` 中调用一次：注册后台任务入口。
Future<void> initBackgroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundServiceEntry,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: uploadNotificationChannelId,
      initialNotificationTitle: '照片同步',
      initialNotificationContent: '上传服务已启动',
      foregroundServiceNotificationId: uploadNotificationId,
      foregroundServiceTypes: const [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: backgroundServiceEntry,
      onBackground: iosBackgroundEntry,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> iosBackgroundEntry(ServiceInstance service) async => true;

/// 后台 isolate 入口。这里只能使用纯 Dart / 已注册插件，不要碰 UI。
@pragma('vm:entry-point')
void backgroundServiceEntry(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  try {
    final controller = _BackgroundController(service);
    await controller.start();
  } catch (error, stack) {
    // 后台 isolate 里出错不会传到 UI，至少留一份记录并结束服务。
    CrashLog.record('isolate', '$error', stack);
  }
}

class _BackgroundController {
  _BackgroundController(this.service);

  final ServiceInstance service;

  AppPaths? _paths;
  final List<String> _queue = [];
  final Set<String> _seen = {};
  String? _activeJobId;
  JobControl? _control;
  bool _busy = false;
  bool _stopping = false;
  DateTime _lastNotificationAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> start() async {
    service.on('runJob').listen(_onRunJob);
    service.on('pauseJob').listen((event) {
      final jobId = '${event?['jobId']}';
      if (jobId == _activeJobId) _control?.pause();
    });
    service.on('resumeJob').listen((event) {
      final jobId = '${event?['jobId']}';
      if (jobId == _activeJobId) _control?.resume();
    });
    service.on('cancelJob').listen((event) {
      final jobId = '${event?['jobId']}';
      if (jobId == _activeJobId) _control?.cancel();
    });
    service.on('stopService').listen((_) => service.stopSelf());
  }

  Future<void> _onRunJob(Map<String, dynamic>? event) async {
    final args = event ?? const <String, dynamic>{};
    final jobId = '${args['jobId'] ?? ''}';
    final root = '${args['root'] ?? ''}';
    if (jobId.isEmpty) return;
    if (root.isNotEmpty && _paths == null) {
      _paths = AppPaths(Directory(root));
      await _paths!.ensureDirectories();
      // 让后台 isolate 的异常也能落到 crash.log（每个 isolate 各装一次）。
      await CrashLog.init(_paths!.root);
      await _recover();
    }
    if (_paths == null) return;
    if (_seen.contains(jobId)) return;
    _seen.add(jobId);
    _queue.add(jobId);
    unawaited(_pump());
  }

  /// 服务被系统重启后，把“等待中/上传中”的残留任务捡回来。
  Future<void> _recover() async {
    final paths = _paths;
    if (paths == null) return;
    try {
      if (!await paths.jobsDir.exists()) return;
      final specs = <String>[];
      await for (final entity in paths.jobsDir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.spec.json')) continue;
        specs.add(name.substring(0, name.length - '.spec.json'.length));
      }
      specs.sort();
      for (final jobId in specs) {
        if (_seen.contains(jobId)) continue;
        final status = await JsonFile(paths.jobStatusFile(jobId)).readObject();
        final state = status == null ? JobState.queued : JobState.values.firstWhere(
              (e) => e.name == status['state'],
              orElse: () => JobState.queued,
            );
        if (state == JobState.queued || state == JobState.running) {
          _seen.add(jobId);
          _queue.add(jobId);
        }
      }
    } catch (_) {
      // 恢复失败不影响新任务
    }
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final jobId = _queue.removeAt(0);
        await _runJob(jobId);
      }
    } finally {
      _busy = false;
      _scheduleStopIfIdle();
    }
  }

  Future<void> _runJob(String jobId) async {
    final paths = _paths!;
    final specJson = await JsonFile(paths.jobSpecFile(jobId)).readObject();
    if (specJson == null) return;
    final spec = UploadJobSpec.fromJson(specJson);
    final control = JobControl();
    _control = control;
    _activeJobId = jobId;

    await _notify(
      title: '正在上传',
      content: '准备上传 ${spec.items.length} 个文件',
      force: true,
    );

    final hashCache = HashCache(paths.hashCacheFile);
    await hashCache.load();

    final runner = UploadRunner(
      spec: spec,
      statusFile: paths.jobStatusFile(jobId),
      resultsFile: paths.jobResultsFile(jobId),
      control: control,
      canUseNetwork: () => NetworkInspector.hasUsableNetwork(wifiOnly: spec.wifiOnly),
      onStatus: _onStatus,
      hashCache: hashCache,
    );

    JobStatus status;
    try {
      status = await runner.run();
    } catch (error) {
      status = JobStatus(
        state: JobState.failed,
        done: 0,
        failed: spec.items.length,
        skipped: 0,
        total: spec.items.length,
        doneBytes: 0,
        totalBytes: spec.items.fold(0, (sum, item) => sum + item.size),
        message: '任务异常结束：$error',
        updatedAt: DateTime.now(),
      );
      await JsonFile(paths.jobStatusFile(jobId)).writeAtomic(status.toJson());
    }

    try {
      await hashCache.save();
    } catch (_) {
      // 哈希缓存写失败不影响任务结果。
    }

    _activeJobId = null;
    _control = null;
    await _notify(
      title: status.state == JobState.completed ? '上传完成' : '上传已停止',
      content: _summary(status),
      force: true,
    );
  }

  Future<void> _onStatus(JobStatus status) async {
    if (status.state == JobState.paused) {
      await _notify(
        title: '上传已暂停',
        content: status.message ?? '等待继续',
      );
      return;
    }
    if (status.state != JobState.running) return;
    final processed = status.processed;
    final text = status.total > 0
        ? '$processed/${status.total} 个文件 · ${_percent(status.progress)}'
        : '准备中…';
    await _notify(title: '正在上传照片', content: text);
  }

  Future<void> _notify({
    required String title,
    required String content,
    bool force = false,
  }) async {
    if (service is! AndroidServiceInstance) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastNotificationAt) < const Duration(seconds: 2)) {
      return;
    }
    _lastNotificationAt = now;
    try {
      (service as AndroidServiceInstance)
          .setForegroundNotificationInfo(title: title, content: content);
    } catch (_) {
      // 通知更新失败不影响上传
    }
  }

  void _scheduleStopIfIdle() {
    if (_stopping || _busy || _queue.isNotEmpty) return;
    _stopping = true;
    Future<void>.delayed(const Duration(seconds: 5), () {
      _stopping = false;
      if (!_busy && _queue.isEmpty && _activeJobId == null) {
        service.stopSelf();
      }
    });
  }

  static String _percent(double value) => '${(value * 100).toStringAsFixed(0)}%';

  static String _summary(JobStatus status) {
    final failed = status.failed > 0 ? '，${status.failed} 个失败' : '';
    final skipped = status.skipped > 0 ? '，${status.skipped} 个已存在' : '';
    return '成功 ${status.done} 个$skipped$failed · ${FmtBytes.format(status.doneBytes)}';
  }
}

/// 简单字节格式化，避免 isolate 里引入 Flutter 相关代码。
class FmtBytes {
  const FmtBytes._();
  static String format(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[index]}';
  }
}

/// UI 侧：驱动后台服务执行上传任务。
class UploadBackgroundService {
  UploadBackgroundService._();

  static final UploadBackgroundService instance = UploadBackgroundService._();

  final FlutterBackgroundService _service = FlutterBackgroundService();

  Future<void> init() => initBackgroundService();

  /// 写入任务描述并把任务交给后台服务。
  Future<void> enqueue(UploadJobSpec spec, AppPaths paths) async {
    await JsonFile(paths.jobSpecFile(spec.id)).writeAtomic(spec.toJson());
    for (final file in [paths.jobStatusFile(spec.id), paths.jobResultsFile(spec.id)]) {
      if (await file.exists()) await file.delete();
    }
    if (!await _service.isRunning()) {
      await _service.startService();
    }
    final payload = {'jobId': spec.id, 'root': paths.root.path};
    _service.invoke('runJob', payload);
    // 首次启动服务时，监听器可能还没注册好，延迟重发一次；服务端按 jobId 去重。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _service.invoke('runJob', payload);
  }

  Future<void> pause(String jobId) async {
    if (await _service.isRunning()) _service.invoke('pauseJob', {'jobId': jobId});
  }

  Future<void> resume(String jobId) async {
    if (await _service.isRunning()) _service.invoke('resumeJob', {'jobId': jobId});
  }

  Future<void> cancel(String jobId) async {
    if (await _service.isRunning()) _service.invoke('cancelJob', {'jobId': jobId});
  }

  Future<void> stop() async {
    if (await _service.isRunning()) {
      _service.invoke('stopService', const {});
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}

/// 删除任务时用：先取消再删文件。
Future<void> cancelAndRemoveJob(String jobId, AppPaths paths) async {
  await UploadBackgroundService.instance.cancel(jobId);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  for (final file in [
    paths.jobSpecFile(jobId),
    paths.jobStatusFile(jobId),
    paths.jobResultsFile(jobId),
  ]) {
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // 文件可能正被后台读写，忽略
      }
    }
  }
}
