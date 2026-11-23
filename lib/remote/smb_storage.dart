import 'dart:async';
import 'dart:io';

import 'package:smb_connect/smb_connect.dart';

import '../core/app_log.dart';
import '../core/remote_path.dart';
import '../models/storage_config.dart';
import 'options.dart';
import 'remote_storage.dart';

/// 基于 smb_connect（SMB2 / SMB1）的远端存储实现。
///
/// 公开方法与 [RemoteStorage] 的约定一致：路径均相对于配置里的“远端目录”，
/// 没有前导 `/`，例如 `DCIM/2024/05/IMG_0001.jpg`；内部再拼成
/// `/<share>/目录/文件` 的 SMB 绝对路径。
class SmbStorage extends RemoteStorage {
  SmbStorage(StorageConfig config) : super(config);

  static const Duration _connectTimeout = Duration(seconds: 20);
  static const Duration _closeTimeout = Duration(seconds: 5);

  /// Windows 目录属性，用于构造共享根目录。
  static const int _attributeDirectory = 0x10;

  late final SmbOptions _options = SmbOptions.from(config);

  SmbConnect? _client;
  Future<SmbConnect>? _connecting;
  bool _disposed = false;

  @override
  Future<void> open() async {
    await _ensureClient();
  }

  @override
  Future<void> close() async {
    _disposed = true;
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      await client.close().timeout(_closeTimeout);
    } catch (error) {
      // 关闭失败（连接已经断了）不需要打扰用户。
      AppLog.instance.debug('smb', '关闭连接时忽略异常：${_errorText(error)}');
    }
  }

  @override
  Future<String?> test() async {
    final SmbOptions options;
    try {
      options = _options;
    } on RemoteException catch (error) {
      return error.message;
    }

    try {
      await open();
    } catch (error) {
      return _asMessage(error, fallback: '连接 SMB 主机失败', duringConnect: true);
    }

    try {
      await _withConnect(
        (client) => _listDirectory(client, '/${options.share}', ''),
      );
      AppLog.instance.debug('smb', '连接测试成功：${options.host}/${options.share}');
      return null;
    } catch (error) {
      // 有的账号不允许列共享根目录，但共享本身可用；用 listShares 兜底确认。
      if (await _shareExists(options)) {
        AppLog.instance.debug('smb', '共享存在但无法列目录：${options.host}/${options.share}');
        return null;
      }
      return _asMessage(error, fallback: 'SMB 连接测试失败');
    }
  }

  @override
  Future<void> ensureDir(String dir) async {
    final options = _options;
    final relative = RemotePathUtil.join([dir]);
    final absolute = options.fullPath(relative);
    try {
      await _withConnect((client) => _ensureDirectory(client, relative));
      AppLog.instance.debug('smb', '目录已就绪：$absolute');
    } catch (error) {
      throw _translate(error, fallback: '创建远端目录失败：$absolute');
    }
  }

  @override
  Future<bool> exists(String path) async {
    final options = _options;
    final relative = RemotePathUtil.join([path]);
    final absolute = options.fullPath(relative);
    try {
      final file = await _withConnect((client) => _fileOrNull(client, absolute));
      return file != null && file.isExists;
    } catch (error) {
      throw _translate(error, fallback: '检查远端路径失败：$absolute');
    }
  }

  @override
  Future<RemoteEntry?> stat(String path) async {
    final options = _options;
    final relative = RemotePathUtil.join([path]);
    final absolute = options.fullPath(relative);
    try {
      final file = await _withConnect((client) => _fileOrNull(client, absolute));
      if (file == null || !file.isExists) return null;
      final isDirectory = file.isDirectory();
      return RemoteEntry(
        path: relative,
        name: relative.isEmpty ? options.share : RemotePathUtil.basename(relative),
        size: isDirectory ? 0 : file.size,
        isDirectory: isDirectory,
        modified: _modifiedOf(file),
      );
    } catch (error) {
      throw _translate(error, fallback: '读取远端信息失败：$absolute');
    }
  }

  @override
  Future<List<RemoteEntry>> list(String dir) async {
    final options = _options;
    final relative = RemotePathUtil.join([dir]);
    final absolute = options.fullPath(relative);
    try {
      return await _withConnect(
        (client) => _listDirectory(client, absolute, relative),
      );
    } catch (error) {
      throw _translate(error, fallback: '列出远端目录失败：$absolute');
    }
  }

  @override
  Future<void> delete(String path) async {
    final options = _options;
    final relative = RemotePathUtil.join([path]);
    if (relative.isEmpty) {
      throw RemoteException('不允许删除存储根目录');
    }
    final absolute = options.fullPath(relative);
    try {
      await _withConnect((client) async {
        final file = await _fileOrNull(client, absolute);
        if (file == null || !file.isExists) return;
        await client.delete(file);
      });
      AppLog.instance.debug('smb', '已删除 $absolute');
    } catch (error) {
      throw _translate(error, fallback: '删除远端文件失败：$absolute');
    }
  }

  @override
  Future<void> uploadOnce(
    File file,
    String remotePath, {
    UploadProgress? onProgress,
    CancelCheck? isCancelled,
  }) async {
    final options = _options;
    final relative = RemotePathUtil.join([remotePath]);
    if (relative.isEmpty) {
      throw RemoteException('远端文件路径不能为空');
    }
    if (isCancelled?.call() ?? false) {
      throw const UploadCancelledException();
    }

    final int total;
    try {
      total = await file.length();
    } on FileSystemException catch (error) {
      throw RemoteException('读取本地文件失败：${error.message}');
    }

    final parentRelative = RemotePathUtil.dirname(relative);
    final absolute = options.fullPath(relative);
    onProgress?.call(0, total);

    try {
      await _withConnect((client) async {
        await _ensureDirectory(client, parentRelative);
        if (isCancelled?.call() ?? false) {
          throw const UploadCancelledException();
        }

        final existing = await _fileOrNull(client, absolute);
        if (existing != null && existing.isExists) {
          if (existing.isDirectory()) {
            throw RemoteException('远端已存在同名文件夹：$absolute');
          }
          // smb_connect 的 openWrite 不会截断已有文件，必须先删除再重建，
          // 否则新文件比旧文件短时会残留旧内容。
          await client.delete(existing);
        }

        final created = await client.createFile(absolute);
        if (!created.isExists) {
          throw RemoteException('创建远端文件失败：$absolute', retryable: true);
        }

        IOSink? sink;
        try {
          sink = await client.openWrite(created);
          await sink.addStream(
            _progressStream(
              file.openRead(),
              total: total,
              onProgress: onProgress,
              isCancelled: isCancelled,
            ),
          );
          if (isCancelled?.call() ?? false) {
            throw const UploadCancelledException();
          }
          await sink.flush();
          await sink.close();
        } catch (error) {
          // 任何写入失败都尽量清掉半成品，避免下次被当成完整文件。
          await _closeQuietly(sink);
          await _deleteQuietly(client, absolute);
          rethrow;
        }
      });
      AppLog.instance.debug('smb', '已上传 $absolute（$total 字节）');
    } on UploadCancelledException {
      AppLog.instance.debug('smb', '上传已取消：$absolute');
      rethrow;
    } catch (error) {
      throw _translate(error, fallback: '上传到 $absolute 失败');
    }
  }

  /// 通过 [File.openRead] 的流做背压写入，逐块回调进度并检查取消。
  Stream<List<int>> _progressStream(
    Stream<List<int>> source, {
    required int total,
    UploadProgress? onProgress,
    CancelCheck? isCancelled,
  }) async* {
    var sent = 0;
    await for (final chunk in source) {
      if (isCancelled?.call() ?? false) {
        throw const UploadCancelledException();
      }
      sent += chunk.length;
      onProgress?.call(sent, total);
      yield chunk;
    }
  }

  // ---------------------------------------------------------------------------
  // 连接管理
  // ---------------------------------------------------------------------------

  Future<SmbConnect> _ensureClient() {
    final existing = _client;
    if (existing != null) return Future<SmbConnect>.value(existing);
    return _connecting ??= _connectAndCache().whenComplete(() {
      _connecting = null;
    });
  }

  Future<SmbConnect> _connectAndCache() async {
    final options = _options;
    AppLog.instance.debug(
      'smb',
      '连接 ${options.host} 共享 ${options.share}（根目录：${options.root}）',
    );
    try {
      final client = await SmbConnect.connectAuth(
        host: options.host,
        username: options.username,
        password: options.password,
        domain: options.domain,
        forceSmb1: options.forceSmb1,
        onDisconnect: (client) {
          if (identical(_client, client)) {
            _client = null;
            AppLog.instance.debug('smb', '连接已被远端关闭：${options.host}');
          }
        },
      ).timeout(_connectTimeout);
      _client = client;
      return client;
    } catch (error) {
      _client = null;
      throw _translate(
        error,
        fallback: '无法连接 SMB 主机 ${options.host}',
        duringConnect: true,
      );
    }
  }

  /// 执行操作；连接不可用（断线、超时）时丢弃旧连接并重连重试一次。
  Future<T> _withConnect<T>(
    Future<T> Function(SmbConnect client) action,
  ) async {
    var client = await _ensureClient();
    try {
      return await action(client);
    } on UploadCancelledException {
      rethrow;
    } catch (error) {
      if (!_isConnectionLost(error)) rethrow;
      AppLog.instance.debug('smb', '连接不可用，重连后重试：${_errorText(error)}');
      await _discardClient(client);
      client = await _ensureClient();
      return await action(client);
    }
  }

  Future<void> _discardClient(SmbConnect client) async {
    if (!identical(_client, client)) return;
    _client = null;
    try {
      await client.close().timeout(_closeTimeout);
    } catch (error) {
      AppLog.instance.debug('smb', '丢弃旧连接时忽略异常：${_errorText(error)}');
    }
  }

  // ---------------------------------------------------------------------------
  // 基础操作
  // ---------------------------------------------------------------------------

  /// 等价 path 的 SmbFile；不存在返回 null。
  ///
  /// SMB2 的 file() 对不存在的路径返回 [SmbFile.notExists]，不会抛异常；
  /// 部分服务端（或 SMB1）会直接抛错，这时先尝试列父目录来区分
  /// “确实不存在”和“认证 / 网络错误”，避免把后者误判成不存在。
  Future<SmbFile?> _fileOrNull(SmbConnect client, String absolute) async {
    try {
      return await client.file(absolute);
    } catch (error) {
      if (_isNotFound(error)) return null;
      final segments = pathSegments(absolute);
      // 共享根 / 根路径没有可比较的同级目录，无法用列目录来兜底。
      if (segments.length <= 1) rethrow;
      final parent = '/${segments.sublist(0, segments.length - 1).join('/')}';
      final target = segments.last.toLowerCase();
      final List<SmbFile> siblings;
      try {
        final folder = await _folderFor(client, parent);
        if (!folder.isExists) return null;
        siblings = await client.listFiles(folder);
      } catch (listError) {
        if (_isNotFound(listError)) return null;
        rethrow;
      }
      final found = siblings.any(
        (item) => item.name.toLowerCase() == target,
      );
      if (!found) return null;
      rethrow;
    }
  }

  /// 共享根目录不通过 file() 打开（部分服务端不允许打开目录根），
  /// 直接用已知的 share 名构造一个目录型 SmbFile。
  Future<SmbFile> _folderFor(SmbConnect client, String absolute) async {
    final segments = pathSegments(absolute);
    if (segments.length <= 1) {
      final share = segments.isEmpty ? _options.share : segments.first;
      return SmbFile('/$share', '\\', share, 0, 0, 0, _attributeDirectory, 0, true);
    }
    return client.file(absolute);
  }

  Future<List<RemoteEntry>> _listDirectory(
    SmbConnect client,
    String absolute,
    String relativePrefix,
  ) async {
    final folder = await _folderFor(client, absolute);
    if (!folder.isExists) {
      throw RemoteException('远端目录不存在：$absolute', code: 'not-found');
    }
    final files = await client.listFiles(folder);
    final entries = <RemoteEntry>[];
    for (final file in files) {
      final name = file.name;
      if (name.isEmpty || name == '.' || name == '..') continue;
      final isDirectory = file.isDirectory();
      entries.add(
        RemoteEntry(
          path: RemotePathUtil.join([relativePrefix, name]),
          name: name,
          size: isDirectory ? 0 : file.size,
          isDirectory: isDirectory,
          modified: _modifiedOf(file),
        ),
      );
    }
    return entries;
  }

  Future<void> _ensureDirectory(SmbConnect client, String relative) async {
    final absolute = _options.fullPath(relative);
    final segments = pathSegments(absolute);
    if (segments.isEmpty) return;
    final share = segments.first;
    for (var index = 1; index < segments.length; index++) {
      final current = '/$share/${segments.sublist(1, index + 1).join('/')}';
      final existing = await _fileOrNull(client, current);
      if (existing != null && existing.isExists) {
        if (!existing.isDirectory()) {
          throw RemoteException('远端已存在同名文件，无法创建目录：$current');
        }
        continue;
      }
      try {
        await client.createFolder(current);
      } catch (error) {
        // SMB1 对已存在的目录会报 OBJECT_NAME_COLLISION，复核后再决定。
        if (!_matches(_errorText(error).toLowerCase(), _existsMarkers)) {
          rethrow;
        }
        final again = await _fileOrNull(client, current);
        if (again != null && again.isExists) {
          if (again.isDirectory()) continue;
          throw RemoteException('远端已存在同名文件，无法创建目录：$current');
        }
        rethrow;
      }
    }
  }

  Future<void> _closeQuietly(IOSink? sink) async {
    if (sink == null) return;
    try {
      await sink.close().timeout(_closeTimeout);
    } catch (error) {
      AppLog.instance.debug('smb', '关闭写入流时忽略异常：${_errorText(error)}');
    }
  }

  Future<void> _deleteQuietly(SmbConnect client, String absolute) async {
    try {
      final file = await client.file(absolute);
      if (file.isExists) await client.delete(file);
    } catch (error) {
      AppLog.instance.debug('smb', '清理半成品失败：${_errorText(error)}');
    }
  }

  Future<bool> _shareExists(SmbOptions options) async {
    try {
      final shares = await _withConnect((client) => client.listShares());
      final target = options.share.toLowerCase();
      return shares.any((share) => share.name.toLowerCase() == target);
    } catch (error) {
      AppLog.instance.debug('smb', 'listShares 兜底失败：${_errorText(error)}');
      return false;
    }
  }

  DateTime? _modifiedOf(SmbFile file) {
    final millis = file.lastModified;
    if (millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  // ---------------------------------------------------------------------------
  // 错误处理
  // ---------------------------------------------------------------------------

  String _asMessage(
    Object error, {
    required String fallback,
    bool duringConnect = false,
  }) {
    if (error is RemoteException) return error.message;
    return _translate(error, fallback: fallback, duringConnect: duringConnect)
        .message;
  }

  RemoteException _translate(
    Object error, {
    required String fallback,
    bool duringConnect = false,
  }) {
    if (error is RemoteException) return error;
    if (error is FileSystemException) {
      return RemoteException('读取本地文件失败：${error.message}');
    }

    final raw = _errorText(error);
    final text = raw.toLowerCase();
    final denied = _matches(text, _deniedMarkers);

    if (_matches(text, _authMarkers) || (duringConnect && denied)) {
      return RemoteException(
        'SMB 认证失败，请检查用户名、密码和域是否正确（$raw）',
        code: 'auth',
      );
    }
    if (_matches(text, _shareMissingMarkers)) {
      return RemoteException(
        '共享文件夹不存在或无权访问：${_options.share}（$raw）',
        code: 'share',
      );
    }
    if (error is TimeoutException) {
      return RemoteException(
        duringConnect
            ? '连接 SMB 主机 ${_options.host} 超时，请检查网络'
            : 'SMB 操作超时，请检查网络',
        code: 'timeout',
        retryable: true,
      );
    }
    if (error is SocketException) {
      return RemoteException(
        '无法连接 SMB 主机 ${_options.host}，请检查网络（${error.message}）',
        code: 'network',
        retryable: true,
      );
    }
    if (duringConnect && _matches(text, _connectFailedMarkers)) {
      return RemoteException(
        '无法连接 SMB 主机 ${_options.host}，请检查地址、端口与网络（$raw）',
        code: 'connect',
        retryable: true,
      );
    }
    if (_matches(text, _notFoundMarkers)) {
      return RemoteException('远端路径不存在（$raw）', code: 'not-found');
    }
    if (denied) {
      return RemoteException(
        'SMB 权限不足，请检查账号对共享目录的读写权限（$raw）',
        code: 'denied',
      );
    }
    if (_matches(text, _existsMarkers)) {
      return RemoteException('远端已存在同名项目（$raw）', code: 'exists');
    }
    if (_matches(text, _busyMarkers)) {
      return RemoteException(
        '远端文件正被占用，请稍后重试（$raw）',
        code: 'busy',
        retryable: true,
      );
    }
    if (_matches(text, _diskFullMarkers)) {
      return RemoteException('远端存储空间不足（$raw）', code: 'no-space');
    }
    if (_matches(text, _connectionLostMarkers)) {
      return RemoteException(
        'SMB 连接已断开，请稍后重试（$raw）',
        code: 'connection',
        retryable: true,
      );
    }
    return RemoteException('$fallback（$raw）');
  }

  /// 取出异常的 message。
  ///
  /// smb_connect 的异常都 extends Error 且没有重写 toString，直接
  /// `error.toString()` 只会得到 “Instance of 'SmbException'”，
  /// 所以这里通过 dynamic 读公开的 message 字段。
  String _errorText(Object error) {
    if (error is String) return error;
    try {
      final dynamic value = error;
      final message = value.message;
      if (message is String && message.trim().isNotEmpty) return message;
    } catch (_) {
      // 没有 message 字段时退回 toString。
    }
    return error.toString();
  }

  bool _isNotFound(Object error) {
    if (error is RemoteException) return error.code == 'not-found';
    return _matches(_errorText(error).toLowerCase(), _notFoundMarkers);
  }

  bool _isConnectionLost(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    if (error is RemoteException) return error.retryable;
    return _matches(_errorText(error).toLowerCase(), _connectionLostMarkers);
  }

  static bool _matches(String text, List<String> markers) {
    for (final marker in markers) {
      if (text.contains(marker)) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 路径工具（纯逻辑，单测覆盖）
  // ---------------------------------------------------------------------------

  /// 把路径拆成非空片段，忽略空段与 `.`（不解析 `..`）。
  static List<String> pathSegments(String path) {
    return path
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList(growable: false);
  }

  /// 父路径：`/share/a` => `/share`，`/share` 与 `/` => `/`。
  static String parentPath(String path) {
    final segments = pathSegments(path);
    if (segments.length <= 1) return '/';
    return '/${segments.sublist(0, segments.length - 1).join('/')}';
  }

  /// 路径最后一段，空路径返回空串。
  static String baseName(String path) {
    final segments = pathSegments(path);
    return segments.isEmpty ? '' : segments.last;
  }
}

// smb_connect 的 SmbException.getMessageByCode 返回的是 NtStatus 里的
// 英文描述（如 “Logon failure: unknown user name or bad password.”），
// 因此下面的标记都按这些真实文案匹配。
const List<String> _authMarkers = <String>[
  'logon failure',
  'logon request failed',
  'bad password',
  'password is not correct',
  'password has expired',
  'account currently disabled',
  'account is locked out',
  'no logon servers',
  'authentication failed',
  'auth failed',
  'logon denied',
  'user does not exist',
];

const List<String> _shareMissingMarkers = <String>[
  'network name cannot be found',
  'network_name_not_found',
  'netname_not_found',
  'bad_network_name',
  '共享不存在',
];

const List<String> _connectFailedMarkers = <String>[
  "can't connect",
  'cannot connect',
  'connect failed',
  'connection refused',
  'network is unreachable',
  'no route to host',
  'host is down',
  'timed out',
  'timeout',
];

const List<String> _deniedMarkers = <String>[
  'access is denied',
  'access_denied',
  'access denied',
  'network_access_denied',
  'permission_denied',
  'permission denied',
  'unauthorized',
  'eacces',
];

const List<String> _notFoundMarkers = <String>[
  'cannot find the file',
  'cannot find the path',
  'no_such_file',
  'object_name_not_found',
  'object_path_not_found',
  'no_such_device',
  'not_found',
  'does not exist',
  'file not found',
  '不存在',
];

const List<String> _existsMarkers = <String>[
  'already exists',
  'file exists',
  'object_name_collision',
  'file_exists',
  '已存在',
];

const List<String> _busyMarkers = <String>[
  'being used by another process',
  'cannot access the file',
  'sharing_violation',
  'sharing violation',
  'file_locked',
  'lock_conflict',
  'in use',
  '正被占用',
];

const List<String> _diskFullMarkers = <String>[
  'file system is full',
  'disk_full',
  'disk full',
  'insufficient storage',
  'no space',
  '空间不足',
];

const List<String> _connectionLostMarkers = <String>[
  'socketexception',
  'connection closed',
  'connection reset',
  'connection aborted',
  'connection refused',
  'connection timed out',
  'broken pipe',
  'not connected',
  'disconnected',
  'network is unreachable',
  'no route to host',
  'no longer available',
  'not reachable by the transport',
  'network_name_deleted',
  'unexpected_network_error',
  'transport closed',
  'timeout',
  'timed out',
];
