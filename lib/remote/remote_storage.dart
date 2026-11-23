import 'dart:async';
import 'dart:io';

import '../core/remote_path.dart';
import '../models/storage_config.dart';

typedef UploadProgress = void Function(int sent, int total);
typedef CancelCheck = bool Function();

/// 远端条目（列表 / 存在性检查使用）。
class RemoteEntry {
  const RemoteEntry({
    required this.path,
    required this.name,
    this.size = 0,
    this.isDirectory = false,
    this.modified,
  });

  final String path;
  final String name;
  final int size;
  final bool isDirectory;
  final DateTime? modified;
}

/// 存储服务统一异常。message 直接展示给用户，尽量写人话。
class RemoteException implements Exception {
  RemoteException(
    this.message, {
    this.statusCode,
    this.code,
    this.retryable = false,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool retryable;

  @override
  String toString() => message;
}

/// 用户取消上传。
class UploadCancelledException implements Exception {
  const UploadCancelledException();

  @override
  String toString() => '已取消';
}

/// 存储服务抽象：WebDAV / SMB / S3 共同实现。
abstract class RemoteStorage {
  RemoteStorage(this.config);

  final StorageConfig config;

  /// 资源路径前缀（用户填写的“远端目录”），无前导斜杠。
  String get root => RemotePathUtil.normalizeRoot(config.field('root'));

  String get displayName => config.name;

  /// 建立连接 / 校验配置，失败抛 [RemoteException]。
  Future<void> open();

  Future<void> close();

  /// 连接测试，成功返回 null，失败抛 [RemoteException]。
  Future<String?> test();

  Future<void> ensureDir(String dir);

  Future<bool> exists(String path);

  Future<RemoteEntry?> stat(String path);

  Future<List<RemoteEntry>> list(String dir);

  Future<void> delete(String path);

  /// 上传单个文件，带重试与进度回调。
  Future<void> upload(
    File file,
    String remotePath, {
    UploadProgress? onProgress,
    CancelCheck? isCancelled,
    int retries = 2,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (isCancelled?.call() ?? false) throw const UploadCancelledException();
      try {
        await uploadOnce(file, remotePath, onProgress: onProgress, isCancelled: isCancelled);
        return;
      } on UploadCancelledException {
        rethrow;
      } on RemoteException catch (error) {
        lastError = error;
        if (!error.retryable || attempt == retries) rethrow;
      } on FileSystemException catch (error) {
        lastError = RemoteException('读取本地文件失败：${error.message}', retryable: false);
        rethrow;
      } on SocketException catch (error) {
        lastError = RemoteException('网络连接失败：${error.message}', retryable: true);
        if (attempt == retries) rethrow lastError;
      } on TimeoutException {
        lastError = RemoteException('网络超时', retryable: true);
        if (attempt == retries) rethrow lastError;
      }
      await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
    }
    throw lastError is RemoteException
        ? lastError
        : RemoteException('上传失败：$lastError');
  }

  /// 单次上传实现（不需要处理重试）。
  Future<void> uploadOnce(
    File file,
    String remotePath, {
    UploadProgress? onProgress,
    CancelCheck? isCancelled,
  });

  /// 拼接 root 与相对路径，返回相对路径（无前导 `/`）。
  String resolve(String relative) => RemotePathUtil.join([root, relative]);
}

/// 便捷：把进度转换成百分比。
double progressRatio(int sent, int total) => total <= 0 ? 0 : (sent / total).clamp(0, 1);
