import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用私有目录布局。
///
/// 后台上传 isolate 不依赖插件，只拿到这个对象的根路径即可读写任务文件。
class AppPaths {
  AppPaths(this.root);

  factory AppPaths.of(Directory root) => AppPaths(root);

  final Directory root;

  File file(String name) => File(p.join(root.path, name));

  File get albumsFile => file('albums.json');
  File get storagesFile => file('storages.json');
  File get settingsFile => file('settings.json');
  File get jobsIndexFile => file('jobs.json');

  Directory get jobsDir => Directory(p.join(root.path, 'jobs'));
  Directory get uploadsDir => Directory(p.join(root.path, 'uploads'));
  Directory get logsDir => Directory(p.join(root.path, 'logs'));

  File jobSpecFile(String jobId) => File(p.join(jobsDir.path, '$jobId.spec.json'));
  File jobStatusFile(String jobId) => File(p.join(jobsDir.path, '$jobId.status.json'));
  File jobResultsFile(String jobId) => File(p.join(jobsDir.path, '$jobId.results.jsonl'));

  File uploadsFile(String storageId) =>
      File(p.join(uploadsDir.path, '${_safeId(storageId)}.json'));

  String _safeId(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  Future<void> ensureDirectories() async {
    await root.create(recursive: true);
    await jobsDir.create(recursive: true);
    await uploadsDir.create(recursive: true);
    await logsDir.create(recursive: true);
  }
}
