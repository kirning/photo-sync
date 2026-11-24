import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_log.dart';
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

    // 关键：从磁盘恢复待上传任务。
    // 插件用 Pipe 把事件投递给后台 isolate，而 Pipe.invoke() 在没有监听者时
    // 会**静默丢弃**消息（见 flutter_background_service_android 的 Pipe.java）。
    // 也就是说 startService() 之后 1~2 秒内 UI 发出的 runJob 很可能直接丢了，
    // 任务就会永远停在“上传中 0%”。所以这里不依赖消息，启动即扫盘。
    if (await _ensurePaths()) {
      await _recover();
      unawaited(_pump());
    }
  }

  /// 准备目录结构。UI 没传 root 时自己用 path_provider 取同一个目录，
  /// 这样即使 runJob 消息丢了也能从 jobs/ 里找回任务。
  Future<bool> _ensurePaths([String? rootHint]) async {
    if (_paths != null) return true;
    var root = rootHint ?? '';
    if (root.isEmpty) {
      try {
        root = (await getApplicationSupportDirectory()).path;
      } catch (error) {
        AppLog.instance.warn('bg', '后台取目录失败：$error');
        return false;
      }
    }
    final paths = AppPaths(Directory(root));
    await paths.ensureDirectories();
    await AppLog.instance.init(paths.logsDir);
    // 让后台 isolate 的异常也能落到 crash.log（每个 isolate 各装一次）。
    await CrashLog.init(paths.root);
    _paths = paths;
    AppLog.instance.info('bg', '后台上传服务就绪：$root');
    return true;
  }

  Future<void> _onRunJob(Map<String, dynamic>? event) async {
    final args = event ?? const <String, dynamic>{};
    final jobId = '${args['jobId'] ?? ''}';
    final root = '${args['root'] ?? ''}';
    if (jobId.isEmpty) return;
    if (!await _ensurePaths(root.isEmpty ? null : root)) return;
    // 每个 runJob 事件都顺手扫一遍磁盘，避免漏掉别的任务。
    await _recover();
    if (_seen.contains(jobId)) {
      unawaited(_pump());
      return;
    }
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
    Future<void>.delayed(const Duration(seconds: 5), () async {
      _stopping = false;
      if (_busy || _queue.isNotEmpty || _activeJobId != null) return;
      // 休眠前再扫一次盘：UI 可能刚好在这个空窗期写了新的 spec 文件。
      await _recover();
      if (_queue.isNotEmpty) {
        unawaited(_pump());
        return;
      }
      AppLog.instance.info('bg', '没有待上传任务，关闭后台服务');
      await AppLog.instance.closeFile();
      service.stopSelf();
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
  ///
  /// 返回 true 表示后台已经接手（状态文件出现）。
  Future<bool> enqueue(UploadJobSpec spec, AppPaths paths) async {
    await JsonFile(paths.jobSpecFile(spec.id)).writeAtomic(spec.toJson());
    final statusFile = paths.jobStatusFile(spec.id);
    for (final file in [statusFile, paths.jobResultsFile(spec.id)]) {
      if (await file.exists()) await file.delete();
    }
    final payload = {'jobId': spec.id, 'root': paths.root.path};
    // 插件在后台 isolate 还没注册监听者时会丢掉消息（Pipe.invoke 静默丢弃），
    // 所以这里重试到状态文件出现为止；后台服务启动时也会自己扫盘恢复。
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!await _service.isRunning()) {
        try {
          await _service.startService();
        } catch (error) {
          AppLog.instance.warn('bg', '启动后台上传服务失败：$error');
        }
      }
      _service.invoke('runJob', payload);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await statusFile.exists()) return true;
    }
    AppLog.instance.warn('bg', '后台服务没有响应，任务 ${spec.id} 可能没有开始');
    return false;
  }

  /// 只重新通知后台服务，不动任务文件（用于“任务卡在 0%”时的自愈）。
  Future<void> poke(String jobId, AppPaths paths) async {
    final payload = {'jobId': jobId, 'root': paths.root.path};
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!await _service.isRunning()) {
        try {
          await _service.startService();
        } catch (error) {
          AppLog.instance.warn('bg', '重新启动后台上传服务失败：$error');
        }
      }
      _service.invoke('runJob', payload);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (await paths.jobStatusFile(jobId).exists()) return;
    }
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
