import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/core/file_hash.dart';

void main() {
  late Directory tempDir;
  late File cacheFile;
  late File photo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('photo_sync_hash_');
    cacheFile = File('${tempDir.path}/hashes.json');
    photo = File('${tempDir.path}/photo.jpg');
    await photo.writeAsBytes(List<int>.generate(2048, (index) => index % 251));
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('算出 SHA-256 且重复调用走缓存', () async {
    final cache = HashCache(cacheFile);
    final hash = await cache.hashOf(photo);

    expect(hash, hasLength(64));
    expect(
      hash,
      sha256.convert(await photo.readAsBytes()).toString(),
    );

    final length = await photo.length();
    final mtime = (await photo.lastModified()).millisecondsSinceEpoch;
    expect(cache.cachedHash(photo.path, size: length, modifiedMs: mtime), hash);

    // 同样的大小与修改时间再算一次不会重新读文件：文件删掉后靠传入的
    // size/mtime 仍能命中缓存。
    final removed = File('${tempDir.path}/removed.jpg');
    await removed.writeAsBytes(await photo.readAsBytes());
    final removedHash = await cache.hashOf(removed);
    final removedSize = await removed.length();
    final removedMtime = (await removed.lastModified()).millisecondsSinceEpoch;
    await removed.delete();
    expect(
      await cache.hashOf(removed, size: removedSize, modifiedMs: removedMtime),
      removedHash,
      reason: '文件不在了但缓存命中，不应抛异常',
    );
  });

  test('大小或修改时间变化后缓存失效', () async {
    final cache = HashCache(cacheFile);
    final first = await cache.hashOf(photo);
    final length = await photo.length();
    final mtime = (await photo.lastModified()).millisecondsSinceEpoch;

    expect(cache.cachedHash(photo.path, size: length + 1, modifiedMs: mtime), isNull);
    expect(cache.cachedHash(photo.path, size: length, modifiedMs: mtime + 1), isNull);

    await photo.writeAsBytes([1, 2, 3]);
    final second = await cache.hashOf(photo);
    expect(second, isNot(first));
  });

  test('写盘后可以从新实例读回', () async {
    final cache = HashCache(cacheFile);
    final hash = await cache.hashOf(photo);
    await cache.save();

    expect(await cacheFile.exists(), isTrue);
    final reloaded = HashCache(cacheFile);
    await reloaded.load();
    final length = await photo.length();
    final mtime = (await photo.lastModified()).millisecondsSinceEpoch;
    expect(reloaded.cachedHash(photo.path, size: length, modifiedMs: mtime), hash);
    expect(reloaded.length, 1);
  });

  test('pruneMissing 清掉已删除的路径', () async {
    final cache = HashCache(cacheFile);
    final other = File('${tempDir.path}/other.jpg');
    await other.writeAsBytes([9, 9, 9]);
    await cache.hashOf(photo);
    await cache.hashOf(other);
    expect(cache.length, 2);

    await other.delete();
    cache.pruneMissing();
    expect(cache.length, 1);
  });

  test('缓存文件损坏时按空缓存处理', () async {
    await cacheFile.writeAsString('{not json');
    final cache = HashCache(cacheFile);
    await cache.load();
    expect(cache.length, 0);
    expect(await cache.hashOf(photo), hasLength(64));
  });
}
