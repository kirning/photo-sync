import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/app_log.dart';
import '../core/remote_path.dart';
import 'options.dart';
import 'remote_storage.dart';

/// PROPFIND 响应中的单个条目。
class WebDavEntry {
  const WebDavEntry({
    required this.href,
    required this.path,
    required this.name,
    this.size = 0,
    this.isDirectory = false,
    this.modified,
  });

  /// 服务端返回的原始 href（可能经过 URL 编码）。
  final String href;

  /// URL 解码后的绝对路径，已去掉尾部斜杠，例如 `/dav/photos/a.jpg`。
  final String path;

  /// URL 解码后的最后一段，例如 `a.jpg`。
  final String name;

  final int size;
  final bool isDirectory;
  final DateTime? modified;
}

/// 把相对目录拆成逐段创建的片段（空串返回空列表）。
///
/// 空段、`.`、`..` 会被 [RemotePathUtil.join] 清理，返回值不可变。
List<String> dirSegments(String dir) {
  final normalized = RemotePathUtil.join(<String>[dir]);
  if (normalized.isEmpty) return const <String>[];
  return List<String>.unmodifiable(normalized.split('/'));
}

/// 解析 PROPFIND（Depth 0/1）响应。
///
/// [basePath] 是本次请求的 URL 路径（[Uri.path]，已解码），用于过滤集合自身条目；
/// 传空串则不过滤。返回条目的 [WebDavEntry.name] 已做 URL 解码。
///
/// 支持 `d:` / `D:` / 其他命名空间前缀以及无前缀的标签。
List<WebDavEntry> parsePropfind(
  String xml,
  String basePath, {
  bool includeSelf = false,
}) {
  final entries = <WebDavEntry>[];
  if (xml.isEmpty) return entries;
  final decodedBasePath = _normalizePath(_decodeHref(basePath));
  final blockPattern = RegExp(
    r'<(?:[A-Za-z_][\w.-]*:)?response\b[^>]*>(.*?)</(?:[A-Za-z_][\w.-]*:)?response\s*>',
    caseSensitive: false,
    dotAll: true,
  );
  for (final match in blockPattern.allMatches(xml)) {
    final block = match.group(1) ?? '';
    final href = _tagText(block, 'href');
    if (href == null || href.trim().isEmpty) continue;
    final normalizedPath = _normalizePath(_decodeHref(href));
    if (normalizedPath.isEmpty) continue;
    if (!includeSelf && _isSameEntry(normalizedPath, decodedBasePath)) continue;
    final sizeText = _tagText(block, 'getcontentlength');
    final modifiedText = _tagText(block, 'getlastmodified');
    entries.add(
      WebDavEntry(
        href: href,
        path: normalizedPath,
        name: _lastSegment(normalizedPath),
        size: int.tryParse((sizeText ?? '').trim()) ?? 0,
        isDirectory: _hasCollection(block),
        modified: _parseHttpDate(modifiedText),
      ),
    );
  }
  return entries;
}

/// WebDAV 存储实现：只依赖 dart:io，不引入额外 HTTP / XML 依赖。
///
/// 约定：所有 `path` / `dir` 参数都是“相对 [root] 的路径”（无前导 `/`，
/// 例如 `DCIM/2024/05/IMG_0001.jpg`）；实现内部通过 [resolve] 拼上 root，
/// 再构造真正的请求地址。调用方不需要（也不应该）把 root 带进参数。
class WebDavStorage extends RemoteStorage {
  WebDavStorage(super.config);

  static const Duration _connectTimeout = Duration(seconds: 20);
  static const Duration _requestTimeout = Duration(seconds: 60);
  static const int _maxPropfindBytes = 8 << 20;

  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop>'
      '</d:propfind>';

  static final ContentType _xmlContentType = ContentType(
    'application',
    'xml',
    charset: 'utf-8',
  );

  WebDavOptions? _options;
  HttpClient? _client;

  @override
  Future<void> open() async {
    final options = WebDavOptions.from(config);
    _options = options;
    final stale = _client;
    _client = null;
    stale?.close(force: true);
    AppLog.instance.debug(
      'webdav',
      '打开连接：${options.baseUrl}（root=${options.root.isEmpty ? '/' : options.root}）',
    );
  }

  @override
  Future<void> close() async {
    final client = _client;
    _client = null;
    client?.close(force: true);
    AppLog.instance.debug('webdav', '关闭连接：${config.name}');
  }

  @override
  Future<String?> test() async {
    final options = _requireOptions();
    final uri = options.baseUrl;
    final request = await _open('PROPFIND', uri);
    request.headers.set('Depth', '0');
    request.headers.contentType = _xmlContentType;
    final body = utf8.encode(_propfindBody);
    request.contentLength = body.length;
    request.add(body);

    final response = await _closeRequest(request);
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      await _drain(response);
      AppLog.instance.debug('webdav', '连接测试成功：$uri（HTTP $status）');
      return null;
    }

    final detail = await _errorBody(response);
    AppLog.instance.warn('webdav', '连接测试失败：$uri（HTTP $status）');
    throw _httpError('连接测试', status, detail);
  }

  @override
  Future<void> ensureDir(String dir) async {
    final options = _requireOptions();
    final relative = RemotePathUtil.join(<String>[dir]);
    final fullPath = resolve(relative);
    final segments = dirSegments(fullPath);
    if (segments.isEmpty) return;

    var current = '';
    for (final segment in segments) {
      current = current.isEmpty ? segment : '$current/$segment';
      await _ensureCollection(_uriForRaw(options, current));
    }
  }

  @override
  Future<bool> exists(String path) async {
    final options = _requireOptions();
    final uri = _uriForRaw(options, resolve(RemotePathUtil.join(<String>[path])));
    final request = await _open('HEAD', uri);
    request.contentLength = 0;
    final response = await _closeRequest(request);
    final status = response.statusCode;
    if (status == 200 || status == 204) {
      await _drain(response);
      return true;
    }
    if (status == 404) {
      await _drain(response);
      return false;
    }
    if (status == 401 || status == 403) {
      await _drain(response);
      throw _httpError('检查文件', status);
    }
    await _drain(response);
    if (status == 405 || status == 501) {
      // 部分服务端不允许 HEAD，退回 PROPFIND Depth 0。
      return _propfindExists(uri);
    }
    throw _httpError('检查文件', status);
  }

  @override
  Future<RemoteEntry?> stat(String path) async {
    final options = _requireOptions();
    final relative = RemotePathUtil.join(<String>[path]);
    final uri = _uriForRaw(options, resolve(relative));
    final response = await _sendPropfind(uri);
    final status = response.statusCode;
    if (status == 404) {
      await _drain(response);
      return null;
    }
    if (status != 200 && status != 207) {
      final detail = await _errorBody(response);
      throw _httpError('获取文件信息', status, detail);
    }

    final xml = await _readText(response);
    final entries = parsePropfind(xml, uri.path, includeSelf: true);
    if (entries.isEmpty) return null;
    final entry = entries.first;
    final name = entry.name.isEmpty
        ? RemotePathUtil.basename(relative)
        : entry.name;
    return RemoteEntry(
      path: relative,
      name: name,
      size: entry.size,
      isDirectory: entry.isDirectory,
      modified: entry.modified,
    );
  }

  @override
  Future<List<RemoteEntry>> list(String dir) async {
    final options = _requireOptions();
    final relative = RemotePathUtil.join(<String>[dir]);
    final uri = _uriForRaw(options, resolve(relative));
    final response = await _sendPropfind(uri, depth: '1');
    final status = response.statusCode;
    if (status != 200 && status != 207) {
      final detail = await _errorBody(response);
      throw _httpError('读取目录', status, detail);
    }

    final xml = await _readText(response);
    final entries = parsePropfind(xml, uri.path);
    final result = <RemoteEntry>[];
    for (final entry in entries) {
      if (entry.name.isEmpty) continue;
      result.add(
        RemoteEntry(
          path: RemotePathUtil.join(<String>[relative, entry.name]),
          name: entry.name,
          size: entry.size,
          isDirectory: entry.isDirectory,
          modified: entry.modified,
        ),
      );
    }
    AppLog.instance.debug('webdav', '列出 $uri（${result.length} 项）');
    return result;
  }

  @override
  Future<void> delete(String path) async {
    final options = _requireOptions();
    final relative = RemotePathUtil.join(<String>[path]);
    if (relative.isEmpty) {
      throw RemoteException('不能删除远端根目录');
    }
    final uri = _uriForRaw(options, resolve(relative));
    final request = await _open('DELETE', uri);
    request.contentLength = 0;
    final response = await _closeRequest(request);
    final status = response.statusCode;
    if (status == 200 || status == 204 || status == 404) {
      await _drain(response);
      AppLog.instance.debug('webdav', '删除 $uri（HTTP $status）');
      return;
    }
    final detail = await _errorBody(response);
    throw _httpError('删除', status, detail);
  }

  @override
  Future<void> uploadOnce(
    File file,
    String remotePath, {
    UploadProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) {
      throw const UploadCancelledException();
    }

    final options = _requireOptions();
    final relative = RemotePathUtil.join(<String>[remotePath]);
    if (relative.isEmpty) {
      throw RemoteException('上传路径为空');
    }

    await ensureDir(RemotePathUtil.dirname(relative));

    final int total;
    try {
      total = await file.length();
    } on FileSystemException catch (error) {
      throw RemoteException('读取本地文件失败：${error.message}');
    }

    final uri = _uriForRaw(options, resolve(relative));
    final request = await _open('PUT', uri);
    request.headers.contentType = ContentType.binary;
    request.contentLength = total;
    var sent = 0;
    onProgress?.call(0, total);

    try {
      await request.addStream(
        file.openRead().map((chunk) {
          if (isCancelled?.call() ?? false) {
            throw const UploadCancelledException();
          }
          sent += chunk.length;
          if (sent > total) sent = total;
          onProgress?.call(sent, total);
          return chunk;
        }),
      );

      final response = await _closeRequest(request);
      final status = response.statusCode;
      if (status == 200 || status == 201 || status == 204) {
        await _drain(response);
        AppLog.instance.debug('webdav', '上传 $uri（$total 字节，HTTP $status）');
        return;
      }
      final detail = await _errorBody(response);
      AppLog.instance.warn('webdav', '上传 $uri 失败：HTTP $status');
      throw _httpError('上传文件', status, detail);
    } on UploadCancelledException {
      request.abort();
      AppLog.instance.debug('webdav', '上传已取消：$uri');
      rethrow;
    } on RemoteException {
      request.abort();
      rethrow;
    } on FileSystemException catch (error) {
      request.abort();
      throw RemoteException('读取本地文件失败：${error.message}');
    } on SocketException catch (error) {
      request.abort();
      throw RemoteException('网络连接失败：${error.message}', retryable: true);
    } on IOException catch (error) {
      request.abort();
      throw RemoteException('上传失败：$error', retryable: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  WebDavOptions _requireOptions() {
    final existing = _options;
    if (existing != null) return existing;
    final parsed = WebDavOptions.from(config);
    _options = parsed;
    return parsed;
  }

  HttpClient _ensureClient() {
    final existing = _client;
    if (existing != null) return existing;
    final client = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..idleTimeout = const Duration(seconds: 15);
    if (_requireOptions().allowBadCert) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    _client = client;
    return client;
  }

  /// 统一把网络异常翻译成中文 [RemoteException]。
  Future<T> _io<T>(
    Future<T> future, {
    String action = '网络请求',
    Duration timeout = _requestTimeout,
  }) async {
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      throw RemoteException('$action超时，请检查网络或服务器地址', retryable: true);
    } on HandshakeException catch (error) {
      throw RemoteException(
        'HTTPS 证书校验失败：${error.message}。若使用自签名证书，请开启“忽略证书错误”',
      );
    } on SocketException catch (error) {
      throw RemoteException('无法连接服务器：${error.message}', retryable: true);
    } on IOException catch (error) {
      throw RemoteException('$action失败：$error', retryable: true);
    }
  }

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    final options = _requireOptions();
    final request = await _io(
      _ensureClient().openUrl(method, uri),
      action: '连接服务器',
      timeout: _connectTimeout,
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'photo-sync-webdav/0.1');
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    if (options.username.isNotEmpty || options.password.isNotEmpty) {
      final credentials = base64.encode(
        utf8.encode('${options.username}:${options.password}'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic $credentials',
      );
    }
    return request;
  }

  Future<HttpClientResponse> _closeRequest(HttpClientRequest request) {
    return _io(request.close(), action: '等待服务器响应');
  }

  Future<HttpClientResponse> _sendPropfind(
    Uri uri, {
    String depth = '0',
    int redirects = 0,
  }) async {
    final request = await _open('PROPFIND', uri);
    request.headers.set('Depth', depth);
    request.headers.contentType = _xmlContentType;
    final body = utf8.encode(_propfindBody);
    request.contentLength = body.length;
    request.add(body);
    final response = await _closeRequest(request);
    final status = response.statusCode;
    final isRedirect = status == 301 || status == 302 || status == 307 || status == 308;
    if (isRedirect && redirects < 3) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      await _drain(response);
      if (location == null || location.isEmpty) {
        throw RemoteException(
          '服务器返回重定向（HTTP $status），但缺少 Location 头',
          statusCode: status,
        );
      }
      return _sendPropfind(
        uri.resolve(location),
        depth: depth,
        redirects: redirects + 1,
      );
    }
    return response;
  }

  Future<void> _ensureCollection(Uri uri) async {
    final request = await _open('MKCOL', uri);
    request.contentLength = 0;
    final response = await _closeRequest(request);
    final status = response.statusCode;
    await _drain(response);

    if (status == 200 || status == 201 || status == 204 || status == 405) {
      AppLog.instance.debug('webdav', '创建目录 $uri（HTTP $status）');
      return;
    }
    if (status == 301 || status == 302 || status == 307 || status == 308) {
      // 有些服务端对已存在的集合返回重定向（通常跳到带尾斜杠的地址）。
      AppLog.instance.debug('webdav', '创建目录 $uri（HTTP $status，视为已存在）');
      return;
    }
    if (status == 409) {
      // 409 可能是“父集合不存在”，也可能是部分服务端表示“已存在”，用 PROPFIND 复核。
      if (await _propfindExists(uri)) {
        AppLog.instance.debug('webdav', '创建目录 $uri（409，已存在）');
        return;
      }
    }
    throw _httpError('创建目录', status);
  }

  Future<bool> _propfindExists(Uri uri) async {
    final response = await _sendPropfind(uri);
    final status = response.statusCode;
    if (status == 404) {
      await _drain(response);
      return false;
    }
    if (status == 401 || status == 403) {
      await _drain(response);
      throw _httpError('检查文件', status);
    }
    if (status != 200 && status != 207) {
      final detail = await _errorBody(response);
      throw _httpError('检查文件', status, detail);
    }
    final xml = await _readText(response);
    return parsePropfind(xml, uri.path, includeSelf: true).isNotEmpty;
  }

  /// 拼接 baseUrl 与“相对 baseUrl”的路径（root 已包含在 [relativeToBase] 内）。
  ///
  /// 与 [WebDavOptions.uriFor] 不同，这里不会再追加 root，供 [ensureDir] 逐段创建
  /// （包括可能缺失的 root 目录）使用。传未编码路径，交给 [Uri.replace] 编码。
  Uri _uriForRaw(WebDavOptions options, String relativeToBase) {
    final clean = RemotePathUtil.join(<String>[relativeToBase]);
    final basePath = options.baseUrl.path.replaceAll(RegExp(r'/+$'), '');
    final path = clean.isEmpty
        ? (basePath.isEmpty ? '/' : basePath)
        : '$basePath/$clean';
    return options.baseUrl.replace(path: path);
  }

  Future<List<int>> _readBytes(
    HttpClientResponse response, {
    int maxBytes = _maxPropfindBytes,
  }) async {
    final bytes = <int>[];
    await _io<void>(
      _collectBody(response, bytes, maxBytes),
      action: '读取服务器响应',
    );
    return bytes;
  }

  Future<void> _collectBody(
    HttpClientResponse response,
    List<int> bytes,
    int maxBytes,
  ) async {
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length >= maxBytes) break;
    }
  }

  Future<String> _readText(
    HttpClientResponse response, {
    int maxBytes = _maxPropfindBytes,
  }) async {
    final bytes = await _readBytes(response, maxBytes: maxBytes);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<String> _errorBody(HttpClientResponse response) async {
    try {
      final text = (await _readText(response, maxBytes: 4096)).trim();
      return text.length > 300 ? text.substring(0, 300) : text;
    } on RemoteException {
      return '';
    }
  }

  Future<void> _drain(HttpClientResponse response) async {
    try {
      await _io<void>(response.drain<void>(), action: '读取服务器响应');
    } on RemoteException {
      // 响应体对结果没有影响，读取失败时忽略（连接会被回收）。
    }
  }

  RemoteException _httpError(String action, int status, [String body = '']) {
    final detail = body.isEmpty ? '' : '（服务端返回：$body）';
    switch (status) {
      case 401:
        return RemoteException(
          '$action失败：用户名或密码错误$detail',
          statusCode: status,
        );
      case 403:
        return RemoteException(
          '$action失败：没有访问权限$detail',
          statusCode: status,
        );
      case 404:
        return RemoteException(
          '$action失败：远端路径不存在$detail',
          statusCode: status,
        );
      case 409:
        return RemoteException(
          '$action失败：父目录不存在或路径冲突$detail',
          statusCode: status,
        );
      case 429:
        return RemoteException(
          '$action失败：请求过于频繁，请稍后重试$detail',
          statusCode: status,
          retryable: true,
        );
      case 507:
        return RemoteException(
          '$action失败：服务器存储空间不足$detail',
          statusCode: status,
        );
    }
    if (status >= 500) {
      return RemoteException(
        '$action失败：服务器异常（HTTP $status）$detail',
        statusCode: status,
        retryable: true,
      );
    }
    return RemoteException(
      '$action失败（HTTP $status）$detail',
      statusCode: status,
      code: 'http_$status',
    );
  }
}

// -----------------------------------------------------------------------------
// XML / 路径解析辅助函数（保持纯函数，便于单测）
// -----------------------------------------------------------------------------

final Map<String, RegExp> _tagTextPatterns = <String, RegExp>{};

String? _tagText(String xml, String localName) {
  final pattern = _tagTextPatterns.putIfAbsent(localName, () {
    final escaped = RegExp.escape(localName);
    return RegExp(
      '<(?:[A-Za-z_][\\w.-]*:)?$escaped\\b[^>]*>(.*?)'
      '</(?:[A-Za-z_][\\w.-]*:)?$escaped\\s*>',
      caseSensitive: false,
      dotAll: true,
    );
  });
  final match = pattern.firstMatch(xml);
  if (match == null) return null;
  return _unescapeXml(match.group(1) ?? '');
}

bool _hasCollection(String xml) {
  return RegExp(
    r'<(?:[A-Za-z_][\w.-]*:)?collection\b[^>]*?>',
    caseSensitive: false,
  ).hasMatch(xml);
}

String _unescapeXml(String text) {
  var value = text.trim();
  if (value.startsWith('<![CDATA[') && value.endsWith(']]>')) {
    return value.substring(9, value.length - 3);
  }
  value = value.replaceAllMapped(
    RegExp(r'&(#x[0-9A-Fa-f]+|#[0-9]+|amp|lt|gt|quot|apos);'),
    (match) {
      final entity = match.group(1) ?? '';
      switch (entity) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      final int? code;
      if (entity.startsWith('#x')) {
        code = int.tryParse(entity.substring(2), radix: 16);
      } else if (entity.startsWith('#')) {
        code = int.tryParse(entity.substring(1));
      } else {
        code = null;
      }
      if (code == null || code < 0 || code > 0x10FFFF) {
        return match.group(0) ?? '';
      }
      return String.fromCharCode(code);
    },
  );
  return value;
}

/// 解码 href：支持完整 URL、绝对路径、经 URL 编码的文件名（含中文 / 空格）。
String _decodeHref(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  final uri = Uri.tryParse(value);
  if (uri != null && uri.path.isNotEmpty) {
    // Uri.path 保留百分号编码，这里统一解成可读路径，
    // 才能和调用方传入的未编码路径做比较。
    try {
      return Uri.decodeFull(uri.path);
    } on FormatException {
      return uri.path;
    }
  }
  try {
    return Uri.decodeFull(value);
  } on FormatException {
    return value;
  }
}

String _normalizePath(String path) {
  var value = path.trim().replaceAll('\\', '/');
  if (value.isEmpty) return '';
  value = value.replaceAll(RegExp(r'/+'), '/');
  if (!value.startsWith('/')) {
    value = '/$value';
  }
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String _lastSegment(String normalizedPath) {
  if (normalizedPath.isEmpty || normalizedPath == '/') return '';
  final parts = normalizedPath.split('/');
  return parts.isEmpty ? '' : parts.last;
}

/// 判断某个 href 是否就是本次请求的集合本身。
///
/// 除了完全相等，还兼容服务端返回相对 href（如 `photos/`）的情况：
/// 此时在请求路径的末尾做后缀匹配；子项路径必然比集合路径更长，不会误伤。
bool _isSameEntry(String entryPath, String basePath) {
  final base = _normalizePath(basePath);
  if (base.isEmpty) return false;
  final entry = _normalizePath(entryPath);
  if (entry.isEmpty) return false;
  if (entry == base) return true;
  return base.endsWith(entry);
}

DateTime? _parseHttpDate(String? text) {
  final value = text?.trim();
  if (value == null || value.isEmpty) return null;
  try {
    return HttpDate.parse(value);
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}
