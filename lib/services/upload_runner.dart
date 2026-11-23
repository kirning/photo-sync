import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../core/json_file.dart';
import '../core/remote_path.dart';
import '../models/storage_config.dart';
import '../models/upload_job.dart';
import '../remote/remote_storage.dart';
import '../remote/remote_storages.dart';

/// 判断当前网络是否可用（纯 Dart，可在后台 isolate 中运行）。
class NetworkInspector {
  const NetworkInspector._();

  static const List<String> _wifiPrefixes = ['wlan', 'wifi', 'wl', 'eth', 'en', 'br'];
  static const List<String> _mobilePrefixes = [
    'rmnet',
    'ccmni',
    'pdp',
    'radio',
    'clat',
    'v4-rmnet',
  ];
  static const List<String> _vpnPrefixes = ['tun', 'tap', 'ppp', 'utun', 'wg'];

  /// 是否有满足策略的网络。
  ///
  /// Android 上无法直接拿到「当前活跃网络」的计量属性，这里按网卡名做启发式：
  /// - Wi-Fi / 有线：wlan*、eth*、en*、br*
  /// - 移动数据：rmnet*、ccmni*、pdp* 等
  /// - VPN：tun*/ppp*（底层可能是移动数据，wifiOnly 时保守视为不可用）
  static Future<bool> hasUsableNetwork({required bool wifiOnly}) async {
    final interfaces = await _interfaces();
    if (interfaces.isEmpty) return false;
    for (final entry in interfaces.entries) {
      final name = entry.key.toLowerCase();
      final addresses = entry.value;
      if (addresses.isEmpty) continue;
      final isVpn = _vpnPrefixes.any(name.startsWith);
      final isMobile = _mobilePrefixes.any(name.startsWith);
      final isUnmetered = _wifiPrefixes.any(name.startsWith);
      if (!wifiOnly) return true;
      if (isUnmetered && !isVpn && !isMobile) return true;
    }
    return false;
  }

  /// 返回网卡名 -> 可用地址列表。
  static Future<Map<String, List<String>>> _interfaces() async {
    final result = <String, List<String>>{};
    try {
      final list = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in list) {
        final addresses = interface.addresses
            .where((a) => !a.isLoopback)
            .map((a) => a.address)
            .toList(growable: false);
        if (addresses.isNotEmpty) result[interface.name] = addresses;
      }
    } on OSError {
      return {};
    }
    return result;
  }

  /// 给 UI / 日志用的一句话描述。
  static Future<String> describe() async {
    final interfaces = await _interfaces();
    if (interfaces.isEmpty) return '无网络';
    final names = interfaces.keys.toList()..sort();
    return names.join(', ');
  }
}

/// 任务的暂停 / 取消开关。
///
/// 由后台服务在收到 UI 指令时修改；上传线程在每个文件开始前检查。
class JobControl {
  bool cancelled = false;
  bool paused = false;

  /// 暂停状态变化回调（由 [UploadRunner] 注册，用于立即写状态文件）。
  void Function(bool paused)? onPausedChanged;

  /// 取消回调。
  void Function()? onCancelled;

  bool get isCancelled => cancelled;

  void cancel() {
    cancelled = true;
    paused = false;
    onPausedChanged?.call(false);
    onCancelled?.call();
  }

  void pause() {
    if (cancelled || paused) return;
    paused = true;
    onPausedChanged?.call(true);
  }

  void resume() {
    if (!paused) return;
    paused = false;
    onPausedChanged?.call(false);
  }

  /// 暂停时阻塞，取消时抛 [UploadCancelledException]。
  Future<void> checkpoint() async {
    while (paused && !cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (cancelled) throw const UploadCancelledException();
  }
}

/// 在后台 isolate 中执行一个上传任务。
///
/// 所有状态通过两个文件与 UI 通信：
/// - [statusFile]：原子写入的进度快照；
/// - [resultsFile]：每个文件一行 JSON，用于恢复“已上传”索引。
class UploadRunner {
  UploadRunner({
    required this.spec,
    required this.statusFile,
    required this.resultsFile,
    required this.control,
    required this.canUseNetwork,
    this.onStatus,
    this.networkPollInterval = const Duration(seconds: 5),
    this.statusMinInterval = const Duration(milliseconds: 400),
    this.storageFactory = RemoteStorages.create,
  }) {
    control.onPausedChanged = _handlePausedChanged;
    control.onCancelled = _handleCancelled;
  }

  final UploadJobSpec spec;
  final File statusFile;
  final File resultsFile;
  final JobControl control;
  final Future<bool> Function() canUseNetwork;
  final void Function(JobStatus status)? onStatus;
  final Duration networkPollInterval;
  final Duration statusMinInterval;

  /// 创建存储客户端；默认按配置选择 WebDAV / SMB / S3，测试可注入假实现。
  final RemoteStorage Function(StorageConfig config) storageFactory;

  int _done = 0;
  int _failed = 0;
  int _skipped = 0;
  int _completedBytes = 0;
  int _nextIndex = 0;
  bool _abort = false;
  String? _abortMessage;

  final Map<int, int> _activeSent = {};

  JobState _state = JobState.running;
  String? _message;
  String? _currentName;

  double _speed = 0;
  DateTime _lastRateAt = DateTime.now();
  int _lastRateBytes = 0;
  DateTime? _lastPublishAt;
  bool _networkBlocked = false;

  Future<void> _statusLock = Future<void>.value();
  Future<void> _resultLock = Future<void>.value();

  int get _totalBytes => spec.items.fold(0, (sum, item) => sum + item.size);

  int get _doneBytes =>
      _completedBytes + _activeSent.values.fold(0, (sum, value) => sum + value);

  /// 运行任务，返回最终状态。
  Future<JobStatus> run() async {
    _lastRateAt = DateTime.now();
    await _publish(force: true);

    if (spec.items.isEmpty) {
      _state = JobState.completed;
      _message = '没有需要上传的文件';
      return _finish();
    }

    final workerCount = math.max(1, math.min(spec.concurrency, 4));
    final storages = <RemoteStorage>[];
    try {
      for (var i = 0; i < workerCount; i++) {
        final storage = storageFactory(spec.storage);
        await storage.open();
        storages.add(storage);
      }
    } catch (error) {
      for (final storage in storages) {
        try {
          await storage.close();
        } catch (_) {
          // 忽略
        }
      }
      _state = JobState.failed;
      _message = _humanError(error);
      return _finish();
    }

    try {
      await Future.wait([
        for (var i = 0; i < storages.length; i++) _worker(i, storages[i]),
      ]);
    } on UploadCancelledException {
      _state = JobState.cancelled;
      _message = '已取消';
    } catch (error) {
      _state = JobState.failed;
      _message = _humanError(error);
    } finally {
      for (final storage in storages) {
        try {
          await storage.close();
        } catch (_) {
          // 忽略
        }
      }
    }

    if (_state == JobState.running) {
      _state = _abort ? JobState.failed : JobState.completed;
      if (_abort) _message = _abortMessage;
    }
    return _finish();
  }

  Future<void> _worker(int id, RemoteStorage storage) async {
    while (!_abort) {
      if (control.cancelled) throw const UploadCancelledException();
      await control.checkpoint();
      await _awaitNetwork();
      await control.checkpoint();

      final index = _nextIndex;
      if (index >= spec.items.length) return;
      _nextIndex = index + 1;

      await _process(storage, id, spec.items[index]);
    }
  }

  Future<void> _process(RemoteStorage storage, int workerId, JobItem item) async {
    _currentName = item.name;
    _activeSent[workerId] = 0;
    await _publish();

    final existingRemote = spec.existingRemotePaths[item.path];
    if (existingRemote != null && existingRemote.isNotEmpty) {
      _skipped++;
      _completedBytes += item.size;
      _activeSent[workerId] = 0;
      await _writeResult(JobResult(
        path: item.path,
        name: item.name,
        albumName: item.albumName,
        size: item.size,
        modifiedMs: item.modifiedMs,
        status: 'skipped',
        remotePath: existingRemote,
      ));
      await _publish(force: true);
      return;
    }

    final localFile = File(item.path);
    if (!await localFile.exists()) {
      await _fail(item, '本地文件不存在');
      return;
    }

    final modified = item.modifiedMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(item.modifiedMs)
        : DateTime.now();
    final folder = RemotePathUtil.join(RemotePathUtil.folderSegments(
      template: spec.folderTemplate,
      albumName: item.albumName,
      date: modified,
    ));
    final folderKey = folder.toLowerCase();
    final taken = _takenNames.putIfAbsent(folderKey, () => <String>{});
    var fileName = RemotePathUtil.uniqueFileName(item.name, taken);
    taken.add(fileName.toLowerCase());
    var remotePath = RemotePathUtil.join([folder, fileName]);

    try {
      if (folder.isNotEmpty) await storage.ensureDir(folder);

      // 远端已存在同名文件：大小一致视为已上传，否则换个名字再传。
      final remoteEntry = await storage.stat(remotePath);
      if (remoteEntry != null && !remoteEntry.isDirectory) {
        if (remoteEntry.size == item.size) {
          _skipped++;
          _completedBytes += item.size;
          _activeSent[workerId] = 0;
          await _writeResult(JobResult(
            path: item.path,
            name: item.name,
            albumName: item.albumName,
            size: item.size,
            modifiedMs: item.modifiedMs,
            status: 'skipped',
            remotePath: remotePath,
          ));
          await _publish(force: true);
          return;
        }
        fileName = RemotePathUtil.uniqueFileName(item.name, taken);
        taken.add(fileName.toLowerCase());
        remotePath = RemotePathUtil.join([folder, fileName]);
      }

      final size = item.size > 0 ? item.size : await localFile.length();
      await storage.upload(
        localFile,
        remotePath,
        isCancelled: () => control.cancelled,
        onProgress: (sent, total) {
          _activeSent[workerId] = sent;
          _refreshSpeed();
          unawaited(_publish());
        },
      );

      _done++;
      _completedBytes += size;
      _activeSent[workerId] = 0;
      _consecutiveFailures = 0;
      await _writeResult(JobResult(
        path: item.path,
        name: item.name,
        albumName: item.albumName,
        size: size,
        modifiedMs: item.modifiedMs,
        status: 'uploaded',
        remotePath: remotePath,
      ));
      await _publish(force: true);
    } on UploadCancelledException {
      rethrow;
    } catch (error) {
      _activeSent[workerId] = 0;
      final message = _humanError(error);
      await _fail(item, message);
      if (_isAuthError(error)) {
        _consecutiveFailures += 3;
        if (_consecutiveFailures >= 3) {
          _abort = true;
          _abortMessage = '认证失败，任务已停止：$message';
        }
      } else {
        _consecutiveFailures++;
        if (_consecutiveFailures >= 8) {
          _abort = true;
          _abortMessage = '连续失败 $_consecutiveFailures 次，任务已停止：$message';
        }
      }
    }
  }

  int _consecutiveFailures = 0;
  final Map<String, Set<String>> _takenNames = {};

  Future<void> _fail(JobItem item, String message) async {
    _failed++;
    await _writeResult(JobResult(
      path: item.path,
      name: item.name,
      albumName: item.albumName,
      size: item.size,
      modifiedMs: item.modifiedMs,
      status: 'failed',
      error: message,
    ));
    await _publish(force: true);
  }

  void _handlePausedChanged(bool paused) {
    if (paused) {
      if (_state.isFinished) return;
      _state = JobState.paused;
      _message = '已暂停';
    } else if (_state == JobState.paused && !_networkBlocked) {
      _state = JobState.running;
      _message = null;
    }
    unawaited(_publish(force: true));
  }

  void _handleCancelled() {
    if (_state.isFinished) return;
    _state = JobState.cancelled;
    _message = '已取消';
    unawaited(_publish(force: true));
  }

  Future<void> _awaitNetwork() async {
    var first = true;
    while (!await canUseNetwork()) {
      if (control.cancelled) throw const UploadCancelledException();
      if (first) {
        _networkBlocked = true;
        _state = JobState.paused;
        _message = spec.wifiOnly ? '等待 Wi-Fi 网络…' : '等待网络…';
        await _publish(force: true);
        first = false;
      }
      await Future<void>.delayed(networkPollInterval);
      if (control.cancelled) throw const UploadCancelledException();
    }
    if (_networkBlocked) {
      _networkBlocked = false;
      _state = JobState.running;
      _message = null;
      await _publish(force: true);
    }
  }

  void _refreshSpeed() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRateAt);
    if (elapsed < const Duration(milliseconds: 800)) return;
    final bytes = _doneBytes;
    final delta = bytes - _lastRateBytes;
    final instant = delta / (elapsed.inMilliseconds / 1000);
    _speed = _speed == 0 ? instant : (_speed * 0.6 + instant * 0.4);
    _lastRateAt = now;
    _lastRateBytes = bytes;
  }

  JobStatus _buildStatus() => JobStatus(
        state: _state,
        done: _done,
        failed: _failed,
        skipped: _skipped,
        total: spec.items.length,
        doneBytes: math.min(_doneBytes, _totalBytes),
        totalBytes: _totalBytes,
        currentName: _currentName,
        message: _message,
        speed: _speed,
        updatedAt: DateTime.now(),
      );

  Future<JobStatus> _finish() async {
    _activeSent.clear();
    if (_state == JobState.completed && _failed > 0 && _done == 0 && _skipped == 0) {
      _state = JobState.failed;
      _message ??= '全部文件上传失败';
    }
    if (_state == JobState.completed) {
      _message ??= _failed > 0 ? '完成，$_failed 个文件失败' : '全部完成';
    }
    _currentName = null;
    final status = _buildStatus();
    await _publish(force: true, status: status);
    return status;
  }

  Future<void> _publish({bool force = false, JobStatus? status}) async {
    final now = DateTime.now();
    if (!force && _lastPublishAt != null) {
      if (now.difference(_lastPublishAt!) < statusMinInterval) return;
    }
    _lastPublishAt = now;
    final snapshot = status ?? _buildStatus();
    await _serialStatus(() => JsonFile(statusFile).writeAtomic(snapshot.toJson()));
    onStatus?.call(snapshot);
  }

  Future<void> _writeResult(JobResult result) {
    final line = '${jsonEncode(result.toJson())}\n';
    return _serialResult(() async {
      await resultsFile.parent.create(recursive: true);
      await resultsFile.writeAsString(line, mode: FileMode.append, flush: true);
    });
  }

  Future<void> _serialStatus(Future<void> Function() action) {
    final next = _statusLock.then((_) => action()).catchError((Object _) {});
    _statusLock = next;
    return next;
  }

  Future<void> _serialResult(Future<void> Function() action) {
    final next = _resultLock.then((_) => action()).catchError((Object _) {});
    _resultLock = next;
    return next;
  }

  static bool _isAuthError(Object error) {
    if (error is RemoteException) {
      final code = error.statusCode;
      if (code == 401 || code == 403) return true;
      final text = error.message;
      return text.contains('认证') || text.contains('密码') || text.contains('登录');
    }
    return false;
  }

  static String _humanError(Object error) {
    if (error is RemoteException) return error.message;
    if (error is FileSystemException) return '本地文件读写失败：${error.message}';
    if (error is SocketException) return '网络连接失败：${error.message}';
    if (error is TimeoutException) return '网络超时';
    final text = error.toString();
    return text.length > 300 ? text.substring(0, 300) : text;
  }
}
