import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/core/json_file.dart';
import 'package:photo_sync/data/app_paths.dart';
import 'package:photo_sync/data/app_repository.dart';
import 'package:photo_sync/models/album.dart';
import 'package:photo_sync/models/storage_config.dart';
import 'package:photo_sync/models/upload_job.dart';

void main() {
  late Directory tempDir;
  late AppPaths paths;
  late AppRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('photo_sync_repo_');
    paths = AppPaths(tempDir);
    await paths.ensureDirectories();
    repo = AppRepository(paths);
    await repo.load();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('相册与存储可以持久化并重新加载', () async {
    await repo.addAlbum(
      name: '相机',
      path: '/storage/emulated/0/DCIM/Camera',
      source: AlbumSource.manual,
    );
    await repo.addStorage(StorageConfig(
      id: 's1',
      name: '我的 NAS',
      type: StorageType.smb,
      fields: const {'host': '192.168.1.2', 'share': 'photo'},
      createdAt: DateTime(2026, 5, 1),
    ));

    final reloaded = AppRepository(paths);
    await reloaded.load();
    expect(reloaded.albums.single.name, '相机');
    expect(reloaded.storages.single.name, '我的 NAS');
    expect(reloaded.storages.single.type, StorageType.smb);
  });

  test('任务状态与结果合并后写入上传索引', () async {
    final job = await repo.createJob(
      storageId: 's1',
      storageName: 'NAS',
      albumNames: ['相机'],
      items: [
        const JobItem(
          path: '/storage/emulated/0/DCIM/Camera/a.jpg',
          name: 'a.jpg',
          albumName: '相机',
          size: 100,
          modifiedMs: 0,
        ),
        const JobItem(
          path: '/storage/emulated/0/DCIM/Camera/b.jpg',
          name: 'b.jpg',
          albumName: '相机',
          size: 200,
          modifiedMs: 0,
        ),
      ],
      wifiOnly: true,
    );

    // 模拟后台上传写出的状态与结果文件。
    await JsonFile(paths.jobStatusFile(job.id)).writeAtomic(
      JobStatus(
        state: JobState.completed,
        done: 1,
        failed: 0,
        skipped: 1,
        total: 2,
        doneBytes: 300,
        totalBytes: 300,
        updatedAt: DateTime(2026, 5, 2, 10),
      ).toJson(),
    );
    await paths.jobResultsFile(job.id).writeAsString([
      jsonEncode(const JobResult(
        path: '/storage/emulated/0/DCIM/Camera/a.jpg',
        name: 'a.jpg',
        albumName: '相机',
        size: 100,
        modifiedMs: 0,
        status: 'uploaded',
        remotePath: '相机/2026/05/a.jpg',
      ).toJson()),
      jsonEncode(const JobResult(
        path: '/storage/emulated/0/DCIM/Camera/b.jpg',
        name: 'b.jpg',
        albumName: '相机',
        size: 200,
        modifiedMs: 0,
        status: 'skipped',
        remotePath: '相机/2026/05/b.jpg',
      ).toJson()),
      '',
    ].join('\n'));

    final status = await repo.syncJobFromDisk(job);
    expect(status, isNotNull);
    expect(status!.state, JobState.completed);
    expect(job.state, JobState.completed);
    expect(job.doneCount, 1);
    expect(job.skippedCount, 1);

    expect(repo.uploadedAt('s1', '/storage/emulated/0/DCIM/Camera/a.jpg')?.remotePath,
        '相机/2026/05/a.jpg');
    expect(repo.uploadedAt('s1', '/storage/emulated/0/DCIM/Camera/b.jpg')?.remotePath,
        '相机/2026/05/b.jpg');
    expect(repo.storageIdsFor('/storage/emulated/0/DCIM/Camera/a.jpg'), {'s1'});

    // 删除远端成功后移除标记。
    await repo.removeUpload('s1', '/storage/emulated/0/DCIM/Camera/a.jpg');
    expect(repo.uploadedAt('s1', '/storage/emulated/0/DCIM/Camera/a.jpg'), isNull);

    // 索引要能跨进程恢复。
    final reloaded = AppRepository(paths);
    await reloaded.load();
    expect(reloaded.uploadedAt('s1', '/storage/emulated/0/DCIM/Camera/b.jpg'), isNotNull);
  });

  test('重置上传标记会清空索引文件', () async {
    await repo.recordUploads('s1', [
      UploadedRecord(
        path: '/x/a.jpg',
        storageId: 's1',
        remotePath: 'a.jpg',
        size: 1,
        modifiedMs: 0,
        uploadedAt: DateTime(2026, 5, 2),
        jobId: 'job-1',
      ),
    ]);
    expect(repo.allUploads, hasLength(1));

    await repo.clearUploads('s1');
    expect(repo.allUploads, isEmpty);

    final reloaded = AppRepository(paths);
    await reloaded.load();
    expect(reloaded.allUploads, isEmpty);
  });
}
