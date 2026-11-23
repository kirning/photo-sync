import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sync/models/storage_config.dart';
import 'package:photo_sync/remote/options.dart';
import 'package:photo_sync/remote/remote_storage.dart';
import 'package:photo_sync/remote/webdav_storage.dart';

/// 一个极简的进程内 WebDAV 服务，用来跑通「测试连接 → 建目录 → 上传 → 查询 → 删除」。
///
/// 只实现本项目用到的 PROPFIND / MKCOL / PUT / HEAD / DELETE，
/// 目的是在 CI 里覆盖网络代码路径（包括真实的 HTTP 流式上传），不需要外部服务。
class _DavServer {
  _DavServer(this.username, this.password);

  final String username;
  final String password;
  HttpServer? _server;

  /// 绝对路径（不含末尾斜杠）→ 内容；目录用 [dirs] 记录。
  final Map<String, List<int>> files = {};
  final Set<String> dirs = {'/dav'};

  int get port => _server!.port;
  String get baseUrl => 'http://127.0.0.1:$port/dav';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  bool _authorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null || !header.startsWith('Basic ')) return false;
    final decoded = utf8.decode(base64.decode(header.substring(6)));
    return decoded == '$username:$password';
  }

  Future<void> _handle(HttpRequest request) async {
    // dart:io 的 request.uri.path 仍是百分号编码的，这里解码成真实路径。
    final path = Uri.decodeComponent(request.uri.path);
    if (!_authorized(request)) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Basic realm="WebDAV Authorization Required"',
      );
      await request.response.close();
      return;
    }

    try {
      switch (request.method) {
        case 'PROPFIND':
          await _propfind(request, path);
        case 'MKCOL':
          await _mkcol(request, path);
        case 'PUT':
          await _put(request, path);
        case 'HEAD':
          await _head(request, path);
        case 'DELETE':
          await _delete(request, path);
        default:
          request.response.statusCode = HttpStatus.methodNotAllowed;
          await request.response.close();
      }
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('$error');
      await request.response.close();
    }
  }

  String _normalize(String path) {
    if (path.length > 1 && path.endsWith('/')) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }

  Future<void> _propfind(HttpRequest request, String path) async {
    final target = _normalize(path);
    final isDir = dirs.contains(target);
    final depth = request.headers.value('depth') ?? '0';
    final buffer = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<d:multistatus xmlns:d="DAV:">');

    void entry(String href, {required bool directory, int size = 0}) {
      buffer
        ..write('<d:response><d:href>${Uri.encodeComponent(href).replaceAll('%2F', '/')}</d:href>')
        ..write('<d:propstat><d:prop>')
        ..write('<d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>')
        ..write('<d:getcontentlength>$size</d:getcontentlength>')
        ..write('<d:getlastmodified>Mon, 24 Nov 2026 01:00:00 GMT</d:getlastmodified>')
        ..write('</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>');
    }

    if (!isDir && !files.containsKey(target)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    entry('$target${isDir ? '/' : ''}',
        directory: isDir, size: files[target]?.length ?? 0);

    if (depth != '0') {
      final prefix = '$target/';
      for (final file in files.keys) {
        if (file.startsWith(prefix) && !file.substring(prefix.length).contains('/')) {
          entry(file, directory: false, size: files[file]!.length);
        }
      }
      for (final dir in dirs) {
        if (dir != target &&
            dir.startsWith(prefix) &&
            !dir.substring(prefix.length).contains('/')) {
          entry('$dir/', directory: true);
        }
      }
    }

    buffer.write('</d:multistatus>');
    request.response.statusCode = 207;
    request.response.headers.contentType =
        ContentType('application', 'xml', charset: 'utf-8');
    request.response.write(buffer.toString());
    await request.response.close();
  }

  Future<void> _mkcol(HttpRequest request, String path) async {
    final target = _normalize(path);
    if (dirs.contains(target) || files.containsKey(target)) {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final parent = target.substring(0, target.lastIndexOf('/'));
    if (!dirs.contains(parent)) {
      request.response.statusCode = HttpStatus.conflict;
      await request.response.close();
      return;
    }
    dirs.add(target);
    request.response.statusCode = HttpStatus.created;
    await request.response.close();
  }

  Future<void> _put(HttpRequest request, String path) async {
    final target = _normalize(path);
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    final parent = target.substring(0, target.lastIndexOf('/'));
    if (!dirs.contains(parent)) {
      request.response.statusCode = HttpStatus.conflict;
      await request.response.close();
      return;
    }
    final existed = files.containsKey(target);
    files[target] = bytes;
    request.response.statusCode =
        existed ? HttpStatus.noContent : HttpStatus.created;
    await request.response.close();
  }

  Future<void> _head(HttpRequest request, String path) async {
    final target = _normalize(path);
    final bytes = files[target];
    if (bytes == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response.contentLength = bytes.length;
    await request.response.close();
  }

  Future<void> _delete(HttpRequest request, String path) async {
    final target = _normalize(path);
    if (files.remove(target) != null) {
      request.response.statusCode = HttpStatus.noContent;
    } else if (dirs.remove(target)) {
      request.response.statusCode = HttpStatus.noContent;
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }
}

StorageConfig _config(String url, {String password = 'secret'}) {
  return StorageConfig(
    id: 'test',
    name: '测试 WebDAV',
    type: StorageType.webdav,
    fields: {
      'url': url,
      'username': 'admin',
      'password': password,
      'root': '',
    },
    enabled: true,
    createdAt: DateTime(2026),
  );
}

void main() {
  late _DavServer server;
  late Directory tempDir;

  setUp(() async {
    server = _DavServer('admin', 'secret');
    await server.start();
    tempDir = await Directory.systemTemp.createTemp('photo_sync_dav');
  });

  tearDown(() async {
    await server.stop();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('测试连接：密码正确返回 null，密码错误返回中文提示', () async {
    final ok = WebDavStorage(_config(server.baseUrl));
    expect(await ok.test(), isNull);
    await ok.close();

    final bad = WebDavStorage(_config(server.baseUrl, password: 'wrong'));
    // test() 失败时抛 RemoteException，由 RemoteStorages.test 转成中文提示。
    await expectLater(
      bad.test(),
      throwsA(
        isA<RemoteException>()
            .having((error) => error.message, 'message', contains('密码')),
      ),
    );
    await bad.close();
  });

  test('上传、查询、列举、删除完整链路', () async {
    final file = File('${tempDir.path}/测试 照片.jpg');
    final bytes = List<int>.generate(4096, (index) => index % 256);
    await file.writeAsBytes(bytes);

    final storage = WebDavStorage(_config(server.baseUrl));
    await storage.open();

    final remotePath = '相册/2026/01/图片 1.jpg';
    final progress = <int>[];
    await storage.upload(
      file,
      remotePath,
      onProgress: (sent, total) => progress.add(sent),
    );

    expect(server.files['/dav/相册/2026/01/图片 1.jpg'], hasLength(bytes.length));
    expect(progress.last, bytes.length);

    expect(await storage.exists(remotePath), isTrue);
    final stat = await storage.stat(remotePath);
    expect(stat, isNotNull);
    expect(stat!.size, bytes.length);
    expect(stat.isDirectory, isFalse);

    final entries = await storage.list('相册/2026/01');
    expect(entries.map((entry) => entry.name), contains('图片 1.jpg'));

    await storage.delete(remotePath);
    expect(await storage.exists(remotePath), isFalse);

    await storage.close();
  });

  test('远端同名文件大小不同时，uniqueFileName 能给出新名字', () async {
    final file = File('${tempDir.path}/a.jpg');
    await file.writeAsBytes(List<int>.generate(10, (index) => index));

    final storage = WebDavStorage(_config(server.baseUrl));
    await storage.open();
    await storage.upload(file, 'p/a.jpg');
    await storage.upload(file, 'p/b.jpg');
    expect(await storage.list('p'), hasLength(2));
    await storage.close();
  });

  test('WebDavOptions 解析带 userinfo 的地址与根目录', () {
    final options = WebDavOptions.from(
      _config('https://admin@photo.example.com/originals/'),
    );
    expect(options.username, 'admin');
    expect(options.baseUrl.host, 'photo.example.com');
    // 地址里的路径保留在 baseUrl，拼接时作为前缀使用。
    expect(options.baseUrl.path, '/originals/');
    expect(options.uriFor('2026/a.jpg').path, '/originals/2026/a.jpg');
  });
}
