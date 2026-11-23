import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/core/remote_path.dart';
import 'package:photo_sync/remote/options.dart';
import 'package:photo_sync/remote/webdav_storage.dart';

void main() {
  group('parsePropfind', () {
    const String withPrefix = '<?xml version="1.0" encoding="utf-8"?>'
        '<d:multistatus xmlns:d="DAV:">'
        '<d:response>'
        '<d:href>/dav/photos/</d:href>'
        '<d:propstat><d:prop>'
        '<d:resourcetype><d:collection/></d:resourcetype>'
        '</d:prop></d:propstat>'
        '</d:response>'
        '<d:response>'
        '<d:href>/dav/photos/%E4%B8%AD%E6%96%87%E5%9B%BE%E7%89%87.jpg</d:href>'
        '<d:propstat><d:prop>'
        '<d:resourcetype/>'
        '<d:getcontentlength>1234</d:getcontentlength>'
        '<d:getlastmodified>Mon, 01 Jan 2024 00:00:00 GMT</d:getlastmodified>'
        '</d:prop></d:propstat>'
        '</d:response>'
        '</d:multistatus>';

    test('解析 d: 前缀、过滤集合自身、中文文件名 URL 解码', () {
      final entries = parsePropfind(withPrefix, '/dav/photos');

      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.name, '中文图片.jpg');
      expect(entry.path, '/dav/photos/中文图片.jpg');
      expect(entry.size, 1234);
      expect(entry.isDirectory, isFalse);
      expect(entry.modified, DateTime.utc(2024, 1, 1));
    });

    test('includeSelf 为 true 时保留集合自身并识别目录', () {
      final entries = parsePropfind(withPrefix, '/dav/photos', includeSelf: true);

      expect(entries, hasLength(2));
      final self = entries.first;
      expect(self.name, 'photos');
      expect(self.isDirectory, isTrue);
      expect(self.size, 0);
    });

    test('无命名空间前缀的 XML 也能解析', () {
      const String noPrefix = '<multistatus xmlns="DAV:">'
          '<response><href>/dav/a.txt</href>'
          '<propstat><prop><resourcetype/>'
          '<getcontentlength>0</getcontentlength></prop></propstat>'
          '</response></multistatus>';

      final entries = parsePropfind(noPrefix, '/dav');

      expect(entries, hasLength(1));
      expect(entries.single.name, 'a.txt');
      expect(entries.single.path, '/dav/a.txt');
      expect(entries.single.size, 0);
      expect(entries.single.isDirectory, isFalse);
      expect(entries.single.modified, isNull);
    });

    test('大写 D: 前缀与 %20 空格文件名', () {
      const String upper = '<D:multistatus><D:response>'
          '<D:href>/dav/my%20photo.jpg</D:href>'
          '<D:propstat><D:prop><D:resourcetype/></D:prop></D:propstat>'
          '</D:response></D:multistatus>';

      final entries = parsePropfind(upper, '/dav');

      expect(entries, hasLength(1));
      expect(entries.single.name, 'my photo.jpg');
    });

    test('空响应或非 multistatus 内容返回空列表', () {
      expect(parsePropfind('', '/dav'), isEmpty);
      expect(parsePropfind('<html><body>error</body></html>', '/dav'), isEmpty);
    });
  });

  group('WebDavOptions.uriFor', () {
    WebDavOptions options({
      String base = 'https://example.com/dav',
      String root = 'photos',
    }) {
      return WebDavOptions(
        baseUrl: Uri.parse(base),
        username: 'user',
        password: 'pass',
        root: root,
        allowBadCert: false,
      );
    }

    test('空格只编码一次，不出现 %2520', () {
      final uri = options().uriFor('2024/05/my photo.jpg');

      expect(
        uri.toString(),
        'https://example.com/dav/photos/2024/05/my%20photo.jpg',
      );
      expect(uri.toString(), isNot(contains('%2520')));
      expect('/${uri.pathSegments.join('/')}', '/dav/photos/2024/05/my photo.jpg');
    });

    test('中文按 UTF-8 百分号编码一次', () {
      final uri = options().uriFor('相册/照片.jpg');

      expect('/${uri.pathSegments.join('/')}', '/dav/photos/相册/照片.jpg');
      expect(uri.toString(), contains('%E7%9B%B8%E5%86%8C'));
      expect(uri.toString(), isNot(contains('%25')));
    });

    test('# 号是路径字符而不是 fragment，只编码一次', () {
      final uri = options().uriFor('a#b.jpg');

      expect('/${uri.pathSegments.join('/')}', '/dav/photos/a#b.jpg');
      expect(uri.toString(), endsWith('/a%23b.jpg'));
      expect(uri.hasFragment, isFalse);
      expect(uri.toString(), isNot(contains('%2523')));
    });

    test('baseUrl 自带的 %20 不会被二次编码', () {
      final uri = options(base: 'https://nas.local/dav%20root', root: '')
          .uriFor('a b.jpg');

      expect(uri.toString(), 'https://nas.local/dav%20root/a%20b.jpg');
      expect(uri.toString(), isNot(contains('%2520')));
    });
  });

  group('dirSegments', () {
    test('空目录不产生任何片段', () {
      expect(dirSegments(''), isEmpty);
      expect(dirSegments('   '), isEmpty);
      expect(dirSegments('/'), isEmpty);
    });

    test('按斜杠拆分并清理空段、.、..', () {
      expect(dirSegments('a/b/c'), <String>['a', 'b', 'c']);
      expect(dirSegments('/a//b/./c/'), <String>['a', 'b', 'c']);
      expect(dirSegments('a/../b'), <String>['b']);
      expect(dirSegments('../a'), <String>['a']);
    });

    test('反斜杠与多余空白也会被归一化', () {
      expect(dirSegments(r' a\b '), <String>['a', 'b']);
    });
  });

  group('RemotePathUtil.normalizeRoot', () {
    test('去掉首尾斜杠并折叠重复斜杠', () {
      expect(RemotePathUtil.normalizeRoot(' /photos//2024/ '), 'photos/2024');
    });

    test('反斜杠转正斜杠', () {
      expect(RemotePathUtil.normalizeRoot(r'photos\2024'), 'photos/2024');
    });

    test('丢弃 . 和 .. 段', () {
      expect(RemotePathUtil.normalizeRoot('a/./b/../c'), 'a/b/c');
      expect(RemotePathUtil.normalizeRoot('../photos'), 'photos');
    });

    test('空 root 归一化为空串', () {
      expect(RemotePathUtil.normalizeRoot(''), '');
      expect(RemotePathUtil.normalizeRoot('/'), '');
    });

    test('中文 root 保留', () {
      expect(RemotePathUtil.normalizeRoot('/照片/2024/'), '照片/2024');
    });
  });
}
