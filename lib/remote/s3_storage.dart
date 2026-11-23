import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../core/app_log.dart';
import '../core/remote_path.dart';
import 'aws_sigv4.dart';
import 'options.dart';
import 'remote_storage.dart';

/// S3 及兼容对象存储（AWS S3、MinIO、阿里云 OSS S3 兼容模式等）。
///
/// 路径约定：所有公开方法接收的路径都相对存储根目录（不带前导 `/`），
/// 例如 `DCIM/2024/05/IMG_0001.jpg`。对象 URL 经 [S3Options.uriFor] 拼上
/// 配置里的远端目录（root）；列举对象时用 [resolve] 得到完整 Key 再算前缀。
class S3Storage extends RemoteStorage {
  S3Storage(super.config);

  /// 空 body 的 SHA-256，GET / HEAD / DELETE 签名时使用。
  static const String _emptySha256 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// 单次 PUT 的对象上限（S3 规定 5 GiB），超出需分片上传（暂未实现）。
  static const int _maxSinglePut = 5 * 1024 * 1024 * 1024;

  static const Duration _connectTimeout = Duration(seconds: 60);
  static const Duration _requestTimeout = Duration(seconds: 60);
  static const Duration _uploadTimeout = Duration(minutes: 30);

  /// 单次 list 最多翻页数，避免异常服务端造成死循环（100 页 × 1000 条）。
  static const int _maxListPages = 100;

  S3Options? _options;
  HttpClient? _client;

  S3Options get _opts => _options ??= S3Options.from(config);

  @override
  Future<void> open() async {
    final options = _opts;
    _client ??= _createClient(options);
    AppLog.instance.debug(
      's3',
      '初始化：endpoint=${options.endpoint} bucket=${options.bucket} '
      'region=${options.region} pathStyle=${options.pathStyle} '
      'root="${options.root}"',
    );
  }

  @override
  Future<void> close() async {
    _client?.close(force: true);
    _client = null;
  }

  HttpClient _createClient(S3Options options) {
    final client = HttpClient()
      ..connectionTimeout = _connectTimeout
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'photo-sync/0.1';
    if (options.allowBadCert) {
      client.badCertificateCallback = (cert, host, port) => true;
      AppLog.instance.warn('s3', '已关闭 TLS 证书校验（allowBadCert=true）');
    }
    return client;
  }

  HttpClient _requireClient() => _client ??= _createClient(_opts);

  // ---------------------------------------------------------------- 连接测试

  @override
  Future<String?> test() async {
    final options = _opts;
    final uri = _bucketUri();
    AppLog.instance.debug('s3', '测试连接：HEAD $uri');
    final response = await _send('HEAD', uri, label: '测试连接');
    final status = response.statusCode;
    final requestId = response.headers.value('x-amz-request-id');
    final body = await _readBody(response);
    if (status == 200 || status == 204) {
      AppLog.instance.info(
        's3',
        '测试连接成功：bucket=${options.bucket}（HTTP $status）',
      );
      return null;
    }
    if (status == 401) {
      throw RemoteException(
        'Access Key 或 Secret Key 错误（HTTP 401），请检查密钥是否填写正确',
        statusCode: status,
        code: 'Unauthorized',
      );
    }
    if (status == 403) {
      throw RemoteException(
        '密钥没有访问 Bucket「${options.bucket}」的权限（HTTP 403）：'
        '请确认该密钥允许 s3:ListBucket 操作',
        statusCode: status,
        code: 'AccessDenied',
      );
    }
    if (status == 404) {
      throw RemoteException(
        'Bucket「${options.bucket}」不存在（HTTP 404）：请检查名称与 Region',
        statusCode: status,
        code: 'NoSuchBucket',
      );
    }
    if (status == 301 || status == 307) {
      throw RemoteException(
        'Endpoint 或 Region 不正确（HTTP $status）：'
        '当前 Region 为「${options.region}」，请按服务端要求修改',
        statusCode: status,
        code: 'PermanentRedirect',
      );
    }
    final detail = _responseDetail(body, requestId);
    throw RemoteException(
      '连接 S3 失败（HTTP $status）${detail.isEmpty ? '' : '：$detail'}',
      statusCode: status,
      retryable: _isRetryable(status),
    );
  }

  // ---------------------------------------------------------------- 目录

  @override
  Future<void> ensureDir(String dir) async {
    // 对象存储没有真正的目录，写入对象时前缀会自动存在。
    AppLog.instance.debug('s3', 'ensureDir("$dir")：对象存储无需创建目录');
  }

  @override
  Future<bool> exists(String path) async {
    final response = await _send('HEAD', _objectUri(path), label: '检查对象');
    final status = response.statusCode;
    final body = await _readBody(response);
    if (status == 200) return true;
    if (status == 404) return false;
    if (status == 403) {
      throw RemoteException(
        '没有权限读取对象「$path」（HTTP 403）',
        statusCode: status,
        code: 'AccessDenied',
      );
    }
    throw _errorFor('检查对象「$path」', status, body);
  }

  @override
  Future<RemoteEntry?> stat(String path) async {
    final response = await _send('HEAD', _objectUri(path), label: '获取对象信息');
    final status = response.statusCode;
    final body = await _readBody(response);
    if (status == 404) return null;
    if (status == 200) {
      final size = int.tryParse(
            response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
          ) ??
          0;
      return RemoteEntry(
        path: path,
        name: RemotePathUtil.basename(path),
        size: size,
        modified: _parseHttpDate(
          response.headers.value(HttpHeaders.lastModifiedHeader),
        ),
      );
    }
    if (status == 403) {
      throw RemoteException(
        '没有权限读取对象「$path」（HTTP 403）',
        statusCode: status,
        code: 'AccessDenied',
      );
    }
    throw _errorFor('获取对象信息「$path」', status, body);
  }

  @override
  Future<List<RemoteEntry>> list(String dir) async {
    // ListObjectsV2 的 prefix 必须以 `/` 结尾，否则会混进同前缀的兄弟目录。
    final key = resolve(dir);
    final prefix = key.isEmpty ? '' : (key.endsWith('/') ? key : '$key/');
    final entries = <RemoteEntry>[];
    String? token;
    var pages = 0;
    while (true) {
      final query = <String, String>{
        'list-type': '2',
        'max-keys': '1000',
        'prefix': prefix,
        if (token != null && token.isNotEmpty) 'continuation-token': token,
      };
      final response = await _send(
        'GET',
        _bucketUri(query: query),
        label: '列出目录「$dir」',
      );
      final status = response.statusCode;
      final body = await _readBody(response);
      if (status != 200) {
        throw _errorFor('列出目录「$dir」', status, body);
      }
      final XmlDocument document;
      try {
        document = XmlDocument.parse(body);
      } on Exception catch (error) {
        throw RemoteException('解析 S3 列表响应失败：$error', retryable: true);
      }
      for (final node in document.findAllElements('Contents')) {
        final objectKey = _childText(node, 'Key');
        if (objectKey == null) continue;
        final size = int.tryParse(_childText(node, 'Size') ?? '') ?? 0;
        // 跳过目录占位对象（`xxx/` 且大小为 0）。
        if (objectKey.endsWith('/') && size == 0) continue;
        final relative = _stripRoot(objectKey);
        if (relative == null || relative.isEmpty) continue;
        entries.add(
          RemoteEntry(
            path: relative,
            name: RemotePathUtil.basename(relative),
            size: size,
            modified: _parseIso(_childText(node, 'LastModified')),
          ),
        );
      }
      final truncated =
          (_xmlText(document, 'IsTruncated') ?? '').toLowerCase() == 'true';
      final nextToken = _xmlText(document, 'NextContinuationToken');
      pages++;
      if (!truncated || nextToken == null || nextToken.isEmpty) break;
      if (pages >= _maxListPages) {
        AppLog.instance.warn(
          's3',
          '目录「$dir」列表超过 $_maxListPages 页，已截断',
        );
        break;
      }
      token = nextToken;
    }
    AppLog.instance.debug('s3', '列出目录「$dir」：${entries.length} 个对象');
    return entries;
  }

  @override
  Future<void> delete(String path) async {
    final response = await _send('DELETE', _objectUri(path), label: '删除对象');
    final status = response.statusCode;
    final body = await _readBody(response);
    if (status == 200 || status == 204 || status == 404) {
      AppLog.instance.debug('s3', '删除对象「$path」完成（HTTP $status）');
      return;
    }
    throw _errorFor('删除对象「$path」', status, body);
  }

  // ---------------------------------------------------------------- 上传

  @override
  Future<void> uploadOnce(
    File file,
    String remotePath, {
    UploadProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    if (isCancelled?.call() ?? false) throw const UploadCancelledException();
    if (!await file.exists()) {
      throw RemoteException('本地文件不存在：${file.path}');
    }
    // 先流式算出 sha256 与文件大小（不把整文件读进内存），
    // 再以该 hash 作为 x-amz-content-sha256 签名，服务端可据此校验内容。
    final digest = await _hashFile(file, isCancelled: isCancelled);
    final size = digest.size;
    if (size > _maxSinglePut) {
      throw RemoteException(
        '文件大小 ${_formatSize(size)} 超过单次上传上限 5 GB，暂不支持分片上传',
      );
    }
    final uri = _objectUri(remotePath);
    final signed = _signHeaders('PUT', uri, const <String, String>{}, digest.sha256);
    final client = _requireClient();
    AppLog.instance.debug(
      's3',
      '上传「$remotePath」：${_formatSize(size)} sha256=${digest.sha256}',
    );

    HttpClientRequest request;
    try {
      request = await client.openUrl('PUT', uri).timeout(_connectTimeout);
    } on TimeoutException {
      throw RemoteException('连接 S3 服务超时（${_connectTimeout.inSeconds} 秒）', retryable: true);
    } on SocketException catch (error) {
      throw RemoteException('无法连接 S3 服务：${error.message}', retryable: true);
    } on HandshakeException catch (error) {
      throw RemoteException(
        '与 S3 服务的 TLS 握手失败：${error.message}'
        '${_opts.allowBadCert ? '' : '（自签名证书可开启“忽略证书校验”）'}',
        retryable: true,
      );
    }
    // 取消 / 中断会让写入失败，提前挂上处理器避免未捕获异常。
    request.done.ignore();
    _applyHeaders(request, const <String, String>{}, signed, contentLength: size);

    final deadline = DateTime.now().add(_uploadTimeout);
    var sent = 0;
    try {
      onProgress?.call(0, size);
      await for (final chunk in file.openRead()) {
        if (isCancelled?.call() ?? false) {
          _abortQuietly(request);
          throw const UploadCancelledException();
        }
        request.add(chunk);
        sent += chunk.length;
        // flush 提供背压，避免大文件在内存里堆积。
        await request.flush();
        onProgress?.call(sent, size);
        if (DateTime.now().isAfter(deadline)) {
          _abortQuietly(request);
          throw RemoteException('上传超时（超过 30 分钟）', retryable: true);
        }
      }
      final response = await request.close().timeout(_uploadTimeout);
      final status = response.statusCode;
      final body = await _readBody(response);
      if (status == 200 || status == 201 || status == 204) {
        onProgress?.call(size, size);
        AppLog.instance.info(
          's3',
          '上传「$remotePath」完成（HTTP $status，${_formatSize(size)}）',
        );
        return;
      }
      throw _errorFor('上传「$remotePath」', status, body);
    } on UploadCancelledException {
      AppLog.instance.info('s3', '上传「$remotePath」已取消');
      rethrow;
    } on RemoteException {
      rethrow;
    } on TimeoutException {
      throw RemoteException('上传「$remotePath」超时', retryable: true);
    } on SocketException catch (error) {
      throw RemoteException(
        '上传「$remotePath」时网络中断：${error.message}',
        retryable: true,
      );
    } on HttpException catch (error) {
      throw RemoteException(
        '上传「$remotePath」失败：${error.message}',
        retryable: true,
      );
    }
  }

  /// 流式计算 sha256 并统计字节数。
  Future<_FileDigest> _hashFile(File file, {CancelCheck? isCancelled}) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    var size = 0;
    try {
      await for (final chunk in file.openRead()) {
        if (isCancelled?.call() ?? false) throw const UploadCancelledException();
        input.add(chunk);
        size += chunk.length;
      }
    } finally {
      input.close();
    }
    final digest = sink.value;
    if (digest == null) {
      throw RemoteException('计算文件校验值失败：${file.path}');
    }
    return _FileDigest(digest.toString(), size);
  }

  // ---------------------------------------------------------------- 请求辅助

  /// 统一请求入口：自动签名并附带空 body 的 payload hash。
  Future<HttpClientResponse> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? payloadHash,
    Duration timeout = _requestTimeout,
    String? label,
  }) async {
    final client = _requireClient();
    final extra = headers ?? const <String, String>{};
    final hash = payloadHash ?? _emptySha256;
    final signed = _signHeaders(method, uri, extra, hash);
    final action = label ?? method;
    AppLog.instance.debug('s3', '$action：$method $uri');
    try {
      final request = await client.openUrl(method, uri).timeout(_connectTimeout);
      // 这些请求都没有 body，显式写 0，避免 HttpClient 改用 chunked。
      _applyHeaders(request, extra, signed, contentLength: 0);
      try {
        return await request.close().timeout(timeout);
      } on TimeoutException {
        _abortQuietly(request);
        throw RemoteException(
          '$action超时（${timeout.inSeconds} 秒）',
          retryable: true,
        );
      }
    } on RemoteException {
      rethrow;
    } on TimeoutException {
      throw RemoteException(
        '连接 S3 服务超时（${_connectTimeout.inSeconds} 秒）',
        retryable: true,
      );
    } on SocketException catch (error) {
      throw RemoteException('无法连接 S3 服务：${error.message}', retryable: true);
    } on HandshakeException catch (error) {
      throw RemoteException(
        '与 S3 服务的 TLS 握手失败：${error.message}'
        '${_opts.allowBadCert ? '' : '（自签名证书可开启“忽略证书校验”）'}',
        retryable: true,
      );
    } on HttpException catch (error) {
      throw RemoteException('$action失败：${error.message}', retryable: true);
    }
  }

  Map<String, String> _signHeaders(
    String method,
    Uri uri,
    Map<String, String> headers,
    String payloadHash,
  ) {
    final options = _opts;
    return AwsSigV4.sign(
      method: method,
      url: uri,
      headers: headers,
      payloadHash: payloadHash,
      credentials: AwsCredentials(
        accessKey: options.accessKey,
        secretKey: options.secretKey,
        sessionToken: options.sessionToken.isEmpty ? null : options.sessionToken,
      ),
      region: options.region,
      service: 's3',
    );
  }

  void _applyHeaders(
    HttpClientRequest request,
    Map<String, String> extra,
    Map<String, String> signed, {
    int? contentLength,
  }) {
    for (final entry in extra.entries) {
      request.headers.set(entry.key, entry.value);
    }
    for (final entry in signed.entries) {
      // host 由 HttpClient 依据 URL 自动生成，签名里的值与之保持一致。
      if (entry.key.toLowerCase() == 'host') continue;
      request.headers.set(entry.key, entry.value);
    }
    if (contentLength != null) request.contentLength = contentLength;
  }

  /// 对象 Key -> URL。路径参数相对 root，由 [S3Options.uriFor] 拼上 root。
  Uri _objectUri(String path) => _opts.uriFor(path);

  /// bucket 根 URL（HEAD bucket / ListObjectsV2 使用，不含 root）。
  ///
  /// 这里不用 `uriFor('')`：`uriFor` 会先调用 `keyFor('')`，root 非空时得到
  /// `/bucket/root`，HEAD 会变成查对象而不是查 bucket（404）。
  Uri _bucketUri({Map<String, String>? query}) {
    final options = _opts;
    final endpoint = options.endpoint;
    final basePath = endpoint.path.replaceAll(RegExp(r'/+$'), '');
    final base = options.pathStyle
        ? endpoint.replace(
            path: '$basePath/${options.bucket}',
            queryParameters: null,
          )
        : endpoint.replace(
            host: '${options.bucket}.${endpoint.host}',
            path: basePath.isEmpty ? '/' : basePath,
            queryParameters: null,
          );
    if (query == null || query.isEmpty) return base;
    // 查询串自行按 AWS 规范编码（空格用 %20 而非 +），保证发送内容与
    // 签名里的 canonical query 完全一致，避免服务端校验失败。
    return Uri.parse('${base.toString()}?${_canonicalQuery(query)}');
  }

  static String _canonicalQuery(Map<String, String> query) {
    final keys = query.keys.toList()..sort();
    return keys
        .map(
          (key) =>
              '${AwsSigV4.awsEncode(key)}=${AwsSigV4.awsEncode(query[key] ?? '')}',
        )
        .join('&');
  }

  Future<String> _readBody(
    HttpClientResponse response, {
    Duration timeout = _requestTimeout,
  }) async {
    try {
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk))
          .timeout(timeout);
      return utf8.decode(bytes, allowMalformed: true);
    } on TimeoutException {
      throw RemoteException('读取 S3 响应超时', retryable: true);
    } on SocketException catch (error) {
      throw RemoteException(
        '读取 S3 响应时网络中断：${error.message}',
        retryable: true,
      );
    } on HttpException catch (error) {
      throw RemoteException('读取 S3 响应失败：${error.message}', retryable: true);
    }
  }

  static void _abortQuietly(HttpClientRequest request) {
    try {
      request.abort();
    } catch (_) {
      // 连接可能已经关闭，忽略即可。
    }
  }

  static bool _isRetryable(int status) =>
      status >= 500 || status == 429 || status == 408;

  // ---------------------------------------------------------------- 错误映射

  RemoteException _errorFor(String action, int status, String body) {
    final code = _xmlField(body, 'Code');
    final message = _xmlField(body, 'Message');
    final retryable = _isRetryable(status);
    const hints = <String, String>{
      'SignatureDoesNotMatch': '签名校验失败，请检查 Secret Key、Region 以及本机时间',
      'InvalidAccessKeyId': 'Access Key 无效',
      'NoSuchBucket': 'Bucket 不存在，请检查名称与 Region',
      'NoSuchKey': '对象不存在',
      'AccessDenied': '当前密钥没有该操作的权限',
      'RequestTimeTooSkewed': '本机时间与服务端偏差过大，请校准系统时间',
      'AuthorizationHeaderMalformed': 'Region 与服务端要求不一致，请检查 Region 配置',
    };
    var hint = hints[code];
    if (hint == null && status == 401) hint = 'Access Key 或 Secret Key 错误';
    if (hint == null && status == 403) hint = '密钥无权限';
    if (hint == null && status == 404) hint = '对象或 Bucket 不存在';
    final buffer = StringBuffer('$action失败（HTTP $status');
    if (code != null) buffer.write(' $code');
    buffer.write('）');
    if (hint != null) buffer.write('：$hint');
    if (message != null) {
      buffer.write('；服务端提示：$message');
    } else {
      final snippet = _describeBody(body);
      if (snippet.isNotEmpty) buffer.write('；响应片段：$snippet');
    }
    return RemoteException(
      buffer.toString(),
      statusCode: status,
      code: code,
      retryable: retryable,
    );
  }

  static String _responseDetail(String body, String? requestId) {
    final code = _xmlField(body, 'Code');
    final message = _xmlField(body, 'Message');
    final parts = <String>[
      if (code != null) code,
      if (message != null) message,
      if (requestId != null && requestId.isNotEmpty) 'request-id=$requestId',
    ];
    if (parts.isNotEmpty) return parts.join('；');
    return _describeBody(body);
  }

  /// 截断响应片段，避免把整页错误信息塞进用户可见文案。
  static String _describeBody(String body) {
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 300) return text;
    return '${text.substring(0, 300)}…';
  }

  // ---------------------------------------------------------------- XML 解析

  static String? _xmlField(String body, String tag) {
    if (body.isEmpty) return null;
    final fromXml = _tryXmlText(body, tag);
    if (fromXml != null) return fromXml;
    // 非 XML 错误页（如反向代理返回的 HTML）退回正则提取。
    final match = RegExp('<$tag>([\\s\\S]*?)</$tag>').firstMatch(body);
    final value = match?.group(1)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static String? _tryXmlText(String body, String tag) {
    try {
      return _xmlText(XmlDocument.parse(body), tag);
    } catch (_) {
      return null;
    }
  }

  static String? _xmlText(XmlDocument document, String tag) {
    final elements = document.findAllElements(tag);
    if (elements.isEmpty) return null;
    final text = elements.first.innerText.trim();
    return text.isEmpty ? null : text;
  }

  static String? _childText(XmlElement element, String tag) {
    for (final child in element.children) {
      if (child is XmlElement && child.name.local == tag) {
        final text = child.innerText.trim();
        return text.isEmpty ? null : text;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- 其他

  /// 完整 Key -> 相对 root 的路径；不在 root 下返回 null。
  String? _stripRoot(String key) {
    final prefix = root;
    if (prefix.isEmpty) return key;
    if (key == prefix) return '';
    if (key.startsWith('$prefix/')) return key.substring(prefix.length + 1);
    return null;
  }

  static DateTime? _parseHttpDate(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(value).toLocal();
    } catch (_) {
      return DateTime.tryParse(value)?.toLocal();
    }
  }

  static DateTime? _parseIso(String? value) {
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 收集 chunked 转换产生的摘要。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class _FileDigest {
  const _FileDigest(this.sha256, this.size);

  final String sha256;
  final int size;
}
