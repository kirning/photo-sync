import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/core/json_file.dart';
import 'package:photo_sync/models/storage_config.dart';
import 'package:photo_sync/models/upload_job.dart';
import 'package:photo_sync/remote/remote_storage.dart';
import 'package:photo_sync/services/upload_runner.dart';

/// 内存里的假远端：只记录路径与大小，便于验证上传流程。
class FakeStorage extends RemoteStorage {
  FakeStorage(super.config);

  final Map<String, int> files = {};
  final Set<String> dirs = {};
  final List<String> uploaded = [];
  int openCount = 0;
  bool closed = false;

  /// 让 stat 返回一个大小不匹配的同名文件，模拟远端已有同名不同内容。
  bool conflictOnFirstStat = false;

  @override
  Future<void> open() async {
    openCount++;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<String?> test() async => null;

  @override
  Future<void> ensureDir(String dir) async {
    dirs.add(dir);
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<RemoteEntry?> stat(String path) async {
    if (conflictOnFirstStat) {
      conflictOnFirstStat = false;
      return RemoteEntry(path: path, name: path, size: (files[path] ?? 1) + 1);
    }
    final size = files[path];
    if (size == null) return null;
    return RemoteEntry(path: path, name: path, size: size);
  }

  @override
  Future<List<RemoteEntry>> list(String dir) async => const [];

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }

  @override
  Future<void> uploadOnce(
    File file,
    String remotePath, {
    UploadProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final length = await file.length();
    onProgress?.call(length ~/ 2, length);
    if (isCancelled?.call() ?? false) throw const UploadCancelledException();
    files[remotePath] = length;
    uploaded.add(remotePath);
    onProgress?.call(length, length);
  }
}

StorageConfig buildConfig() => StorageConfig(
      id: 'storage-1',
      name: '测试存储',
      type: StorageType.webdav,
      fields: const {'url': 'http://127.0.0.1/dav'},
      createdAt: DateTime.now(),
    );

void main() {
  late Directory tempDir;
  late File statusFile;
  late File resultsFile;
  late FakeStorage storage;
  late List<File> localFiles;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('photo_sync_runner_');
    statusFile = File('${tempDir.path}/status.json');
    resultsFile = File('${tempDir.path}/results.jsonl');
    storage = FakeStorage(buildConfig());
    localFiles = [];
    for (var i = 0; i < 3; i++) {
      final file = File('${tempDir.path}/photo_$i.jpg');
      await file.writeAsBytes(List<int>.filled(10 + i, 7));
      localFiles.add(file);
    }
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  UploadRunner buildRunner({
    List<File>? files,
    Map<String, String> existing = const {},
    bool wifiOnly = false,
    Future<bool> Function()? canUseNetwork,
    Duration poll = const Duration(milliseconds: 20),
  }) {
    final items = (files ?? localFiles)
        .map((file) => JobItem(
              path: file.path,
              name: file.uri.pathSegments.last,
              albumName: '相机',
              size: 0,
              modifiedMs: DateTime(2026, 5, 6).millisecondsSinceEpoch,
            ))
        .toList();
    final spec = UploadJobSpec(
      id: 'job-1',
      storage: buildConfig(),
      items: items,
      wifiOnly: wifiOnly,
      folderTemplate: '{album}/{yyyy}/{MM}',
      concurrency: 2,
      existingRemotePaths: existing,
    );
    return UploadRunner(
      spec: spec,
      statusFile: statusFile,
      resultsFile: resultsFile,
      control: JobControl(),
      canUseNetwork: canUseNetwork ?? () async => true,
      networkPollInterval: poll,
      storageFactory: (config) => storage,
    );
  }

  test('上传全部文件并写入结果与状态', () async {
    final runner = buildRunner();
    final status = await runner.run();

    expect(status.state, JobState.completed);
    expect(status.done, 3);
    expect(status.failed, 0);
    expect(storage.uploaded, hasLength(3));
    expect(storage.dirs, contains('相机/2026/05'));

    final lines = await resultsFile.readAsLines();
    expect(lines, hasLength(3));
    for (final line in lines) {
      final json = jsonDecode(line) as Map<String, dynamic>;
      expect(json['status'], 'uploaded');
      expect(json['remotePath'] as String, startsWith('相机/2026/05/photo_'));
    }

    final saved = await JsonFile(statusFile).readObject();
    expect(saved, isNotNull);
    expect(saved!['state'], 'completed');
    expect(saved['done'], 3);
    expect(storage.closed, isTrue);
  });

  test('本地索引里已有的文件直接跳过', () async {
    final existing = {
      localFiles.first.path: '相机/2026/05/photo_0.jpg',
    };
    final runner = buildRunner(existing: existing);
    final status = await runner.run();

    expect(status.state, JobState.completed);
    expect(status.skipped, 1);
    expect(status.done, 2);
    expect(storage.uploaded, hasLength(2));
  });

  test('远端同名但大小不同时换名上传', () async {
    storage.conflictOnFirstStat = true;
    final runner = buildRunner(files: [localFiles.first]);
    final status = await runner.run();

    expect(status.state, JobState.completed);
    expect(status.done, 1);
    expect(status.skipped, 0);
    expect(storage.uploaded.single, isNot('相机/2026/05/photo_0.jpg'));
    expect(storage.uploaded.single, contains('photo_0 (1).jpg'));
  });

  test('无网络时暂停，网络恢复后继续', () async {
    var online = false;
    final runner = buildRunner(
      canUseNetwork: () async => online,
      poll: const Duration(milliseconds: 30),
    );
    final states = <JobState>[];
    final holder = <JobStatus>[];
    final done = runner.run().then((value) {
      holder.add(value);
      return value;
    });

    await Future<void>.delayed(const Duration(milliseconds: 120));
    online = true;

    final status = await done;
    expect(status.state, JobState.completed);
    expect(status.done, 3);
    states.add(status.state);
    expect(holder, hasLength(1));
  });

  test('取消任务后状态为 cancelled', () async {
    final runner = buildRunner(
      canUseNetwork: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return true;
      },
    );
    final done = runner.run();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    runner.control.cancel();

    final status = await done;
    expect(status.state, JobState.cancelled);
  });

  test('连接失败时任务标记为 failed', () async {
    final failing = _FailingStorage(buildConfig());
    final runner = UploadRunner(
      spec: UploadJobSpec(
        id: 'job-2',
        storage: buildConfig(),
        items: [
          JobItem(
            path: localFiles.first.path,
            name: 'photo_0.jpg',
            albumName: '相机',
            size: 0,
            modifiedMs: 0,
          ),
        ],
        wifiOnly: false,
        folderTemplate: '{album}',
        concurrency: 1,
        existingRemotePaths: const {},
      ),
      statusFile: statusFile,
      resultsFile: resultsFile,
      control: JobControl(),
      canUseNetwork: () async => true,
      storageFactory: (config) => failing,
    );

    final status = await runner.run();
    expect(status.state, JobState.failed);
    expect(status.message, contains('密码'));
  });
}

class _FailingStorage extends FakeStorage {
  _FailingStorage(super.config);

  @override
  Future<void> open() async {
    throw RemoteException('用户名或密码错误', statusCode: 401);
  }
}
