import '../core/remote_path.dart';
import '../models/storage_config.dart';
import 'remote_storage.dart';

class WebDavOptions {
  WebDavOptions({
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.root,
    required this.allowBadCert,
  });

  final Uri baseUrl;
  final String username;
  final String password;
  final String root;
  final bool allowBadCert;

  factory WebDavOptions.from(StorageConfig config) {
    final rawUrl = config.field('url').trim();
    final url = Uri.tryParse(rawUrl);
    if (url == null || !url.hasScheme || url.host.isEmpty) {
      throw RemoteException('WebDAV 地址无效，需要形如 https://example.com/dav');
    }
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw RemoteException('WebDAV 地址必须以 http:// 或 https:// 开头');
    }
    return WebDavOptions(
      baseUrl: url,
      username: config.field('username'),
      password: config.field('password'),
      root: RemotePathUtil.normalizeRoot(config.field('root')),
      allowBadCert: config.boolField('allowBadCert'),
    );
  }

  /// 生成访问 [relative] 的完整 URL。
  ///
  /// 这里传“未编码”的路径给 [Uri.replace]，由 Uri 负责百分号编码，
  /// 避免对已经编码过的路径二次编码（%20 -> %2520）。
  Uri uriFor(String relative) {
    final cleanRelative = RemotePathUtil.join([root, relative]);
    final basePath = baseUrl.path.replaceAll(RegExp(r'/+$'), '');
    final path =
        cleanRelative.isEmpty ? (basePath.isEmpty ? '/' : basePath) : '$basePath/$cleanRelative';
    return baseUrl.replace(path: path);
  }
}

class SmbOptions {
  SmbOptions({
    required this.host,
    required this.share,
    required this.domain,
    required this.username,
    required this.password,
    required this.root,
    required this.forceSmb1,
  });

  final String host;
  final String share;
  final String domain;
  final String username;
  final String password;
  final String root;
  final bool forceSmb1;

  factory SmbOptions.from(StorageConfig config) {
    var host = config.field('host').trim();
    if (host.isEmpty) throw RemoteException('请填写 SMB 主机地址');
    if (host.startsWith('smb://')) host = host.substring(6);
    host = host.replaceAll(RegExp(r'/+$'), '');
    if (host.contains('/')) host = host.split('/').first;
    final share = config
        .field('share')
        .trim()
        .replaceAll(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (share.isEmpty) throw RemoteException('请填写共享文件夹名称（share）');
    var username = config.field('username').trim();
    var domain = config.field('domain').trim();
    if (username.contains('\\')) {
      final parts = username.split('\\');
      domain = parts.first;
      username = parts.sublist(1).join('\\');
    }
    return SmbOptions(
      host: host,
      share: share,
      domain: domain,
      username: username,
      password: config.field('password'),
      root: RemotePathUtil.normalizeRoot(config.field('root')),
      forceSmb1: config.boolField('forceSmb1'),
    );
  }

  /// smb_connect 使用的路径：`/share/目录/文件`。
  String fullPath(String relative) {
    final clean = RemotePathUtil.join([root, relative]);
    return clean.isEmpty ? '/$share' : '/$share/$clean';
  }
}

class S3Options {
  S3Options({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    required this.sessionToken,
    required this.root,
    required this.pathStyle,
    required this.allowBadCert,
  });

  final Uri endpoint;
  final String region;
  final String bucket;
  final String accessKey;
  final String secretKey;
  final String sessionToken;
  final String root;
  final bool pathStyle;
  final bool allowBadCert;

  factory S3Options.from(StorageConfig config) {
    var endpointRaw = config.field('endpoint').trim();
    if (endpointRaw.isEmpty) throw RemoteException('请填写 S3 Endpoint，例如 https://s3.us-east-1.amazonaws.com');
    if (!endpointRaw.startsWith('http://') && !endpointRaw.startsWith('https://')) {
      final https = config.boolField('useHttps', true);
      endpointRaw = '${https ? 'https' : 'http'}://$endpointRaw';
    }
    final endpoint = Uri.tryParse(endpointRaw);
    if (endpoint == null || endpoint.host.isEmpty) {
      throw RemoteException('S3 Endpoint 无效');
    }
    final bucket = config.field('bucket').trim();
    if (bucket.isEmpty) throw RemoteException('请填写 Bucket 名称');
    final accessKey = config.field('accessKey').trim();
    final secretKey = config.field('secretKey').trim();
    if (accessKey.isEmpty || secretKey.isEmpty) {
      throw RemoteException('请填写 Access Key 与 Secret Key');
    }
    final region = config.field('region', 'us-east-1').trim();
    return S3Options(
      endpoint: endpoint,
      region: region.isEmpty ? 'us-east-1' : region,
      bucket: bucket,
      accessKey: accessKey,
      secretKey: secretKey,
      sessionToken: config.field('sessionToken').trim(),
      root: RemotePathUtil.normalizeRoot(config.field('root')),
      pathStyle: config.boolField('pathStyle', true),
      allowBadCert: config.boolField('allowBadCert'),
    );
  }

  /// 对象 Key（无前导 `/`）。
  String keyFor(String relative) => RemotePathUtil.join([root, relative]);

  /// 请求 URL：pathStyle 时 bucket 落在路径上，否则落在域名上。
  ///
  /// 与 WebDAV 一样传未编码路径，交给 [Uri.replace] 编码。
  Uri uriFor(String relative, {Map<String, String?>? query}) {
    final key = keyFor(relative);
    final basePath = endpoint.path.replaceAll(RegExp(r'/+$'), '');
    late Uri url;
    if (pathStyle) {
      url = endpoint.replace(
        path: '$basePath/$bucket${key.isEmpty ? '' : '/$key'}',
        queryParameters: null,
      );
    } else {
      url = endpoint.replace(
        host: '$bucket.${endpoint.host}',
        path: key.isEmpty ? (basePath.isEmpty ? '/' : basePath) : '$basePath/$key',
        queryParameters: null,
      );
    }
    if (query != null && query.isNotEmpty) {
      url = url.replace(queryParameters: query.map((k, v) => MapEntry(k, v ?? '')));
    }
    return url;
  }

  /// 用于签名的 Host 头。
  String hostHeader(Uri url) => url.hasPort ? '${url.host}:${url.port}' : url.host;
}
