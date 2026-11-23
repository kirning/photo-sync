import '../models/storage_config.dart';
import 'remote_storage.dart';
import 's3_storage.dart';
import 'smb_storage.dart';
import 'webdav_storage.dart';

/// 根据存储配置创建具体的远端实现。
class RemoteStorages {
  const RemoteStorages._();

  static RemoteStorage create(StorageConfig config) {
    switch (config.type) {
      case StorageType.webdav:
        return WebDavStorage(config);
      case StorageType.smb:
        return SmbStorage(config);
      case StorageType.s3:
        return S3Storage(config);
    }
  }

  /// 连接并测试，返回 null 表示成功，否则返回中文错误。
  static Future<String?> test(StorageConfig config) async {
    RemoteStorage? storage;
    try {
      storage = create(config);
      await storage.open();
      return await storage.test();
    } on RemoteException catch (e) {
      return e.message;
    } catch (e) {
      return '连接失败：$e';
    } finally {
      if (storage != null) {
        try {
          await storage.close();
        } catch (_) {
          // 忽略关闭时的异常
        }
      }
    }
  }
}
