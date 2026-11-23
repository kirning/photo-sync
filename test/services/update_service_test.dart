import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/services/update_service.dart';

Map<String, dynamic> releaseJson({List<Map<String, dynamic>>? assets}) => {
      'tag_name': 'v0.2.0',
      'body': '## 更新内容\n- 支持自动更新',
      'html_url': 'https://github.com/kirning/photo-sync/releases/tag/v0.2.0',
      'published_at': '2026-11-24T02:00:00Z',
      'assets': assets ??
          [
            {
              'name': 'app-arm64-v8a-release.apk',
              'browser_download_url': 'https://example.com/arm64.apk',
              'size': 19900000,
            },
            {
              'name': 'app-armeabi-v7a-release.apk',
              'browser_download_url': 'https://example.com/v7a.apk',
              'size': 18000000,
            },
            {
              'name': 'app-x86_64-release.apk',
              'browser_download_url': 'https://example.com/x64.apk',
              'size': 21300000,
            },
          ],
    };

void main() {
  group('isNewerVersion', () {
    test('逐段比较版本号', () {
      expect(UpdateService.isNewerVersion('0.2.0', '0.1.1'), isTrue);
      expect(UpdateService.isNewerVersion('0.1.10', '0.1.9'), isTrue);
      expect(UpdateService.isNewerVersion('1.0', '0.9.9'), isTrue);
      expect(UpdateService.isNewerVersion('0.1.1', '0.1.1'), isFalse);
      expect(UpdateService.isNewerVersion('0.1.0', '0.1.1'), isFalse);
      expect(UpdateService.isNewerVersion('0.1', '0.1.0'), isFalse);
    });

    test('带前缀 v 或非数字内容也能处理', () {
      expect(UpdateService.isNewerVersion('v0.3.0', '0.2.9'), isTrue);
      expect(UpdateService.isNewerVersion('nightly', '0.2.0'), isFalse);
      expect(UpdateService.isNewerVersion('0.1.1', 'nightly'), isFalse);
    });
  });

  group('parseRelease', () {
    test('解析出标签、说明与下载地址', () {
      final info = UpdateService.parseRelease(releaseJson());
      expect(info.version, '0.2.0');
      expect(info.tagName, 'v0.2.0');
      expect(info.notes, contains('自动更新'));
      expect(info.pageUrl, contains('/releases/tag/v0.2.0'));
      expect(info.hasApk, isTrue);
      expect(info.assetName, 'app-arm64-v8a-release.apk');
      expect(info.apkUrl, 'https://example.com/arm64.apk');
      expect(info.size, 19900000);
      expect(info.publishedAt, DateTime.parse('2026-11-24T02:00:00Z'));
    });

    test('按设备 ABI 选择安装包', () {
      expect(
        UpdateService.parseRelease(releaseJson(), preferredAbi: 'x86_64')
            .assetName,
        'app-x86_64-release.apk',
      );
      expect(
        UpdateService.parseRelease(releaseJson(), preferredAbi: 'armeabi-v7a')
            .assetName,
        'app-armeabi-v7a-release.apk',
      );
    });

    test('没有安装包时仍返回版本信息', () {
      final info = UpdateService.parseRelease(releaseJson(assets: []));
      expect(info.version, '0.2.0');
      expect(info.hasApk, isFalse);
      expect(info.apkUrl, isNull);
    });

    test('只挑 apk 资产', () {
      final info = UpdateService.parseRelease(releaseJson(assets: [
        {
          'name': 'source.tar.gz',
          'browser_download_url': 'https://example.com/source.tar.gz',
          'size': 100,
        },
        {
          'name': 'app-universal-release.apk',
          'browser_download_url': 'https://example.com/universal.apk',
          'size': 22000000,
        },
      ]));
      expect(info.assetName, 'app-universal-release.apk');
    });
  });

  group('download', () {
    late HttpServer server;
    late Directory tempDir;
    late List<int> payload;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('photo_sync_update_');
      payload = List<int>.generate(64 * 1024, (index) => index % 256);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/app.apk') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentLength = payload.length;
          request.response.add(payload);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    UpdateInfo infoFor(String path) => UpdateInfo(
          version: '0.2.0',
          tagName: 'v0.2.0',
          notes: '',
          pageUrl: 'https://example.com',
          apkUrl: 'http://${server.address.address}:${server.port}$path',
          assetName: 'app-arm64-v8a-release.apk',
          size: payload.length,
        );

    test('下载到指定目录并回报进度', () async {
      final progress = <int>[];
      final file = await UpdateService.download(
        infoFor('/app.apk'),
        tempDir,
        onProgress: (received, total) {
          expect(total, payload.length);
          progress.add(received);
        },
      );

      expect(await file.exists(), isTrue);
      expect(file.path, endsWith('app-arm64-v8a-release.apk'));
      expect(await file.readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last, payload.length);
      // 不应留下 .part 文件。
      expect(await File('${file.path}.part').exists(), isFalse);
    });

    test('HTTP 404 转成中文异常', () async {
      await expectLater(
        UpdateService.download(infoFor('/missing.apk'), tempDir,
            onProgress: (_, __) {}),
        throwsA(isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('404'),
        )),
      );
    });

    test('取消下载时抛异常且不留半成品', () async {
      await expectLater(
        UpdateService.download(
          infoFor('/app.apk'),
          tempDir,
          onProgress: (_, __) {},
          isCancelled: () => true,
        ),
        throwsA(isA<UpdateException>().having(
          (error) => error.message,
          'message',
          contains('取消'),
        )),
      );
      final leftovers = await tempDir
          .list()
          .where((entity) => entity.path.endsWith('.part'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}
