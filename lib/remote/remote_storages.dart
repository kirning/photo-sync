import 'dart:async';
import 'dart:isolate';

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

  /// 在独立 isolate 里测试连接。
  ///
  /// 网络请求放主 isolate 会让界面卡住（弱网下尤其明显，系统可能直接判定
  /// 应用无响应），这里统一丢到后台 isolate，并加一层兜底超时。
  static Future<String?> testInBackground(
    StorageConfig config, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    try {
      return await Isolate.run(() => test(config)).timeout(
        timeout,
        onTimeout: () => '测试超时：服务器在 ${timeout.inSeconds} 秒内没有响应',
      );
    } on RemoteException catch (e) {
      return e.message;
    } catch (e) {
      return '测试失败：$e';
    }
  }

  /// 在独立 isolate 里删除远端文件，返回 null 表示成功。
  static Future<String?> deleteInBackground(
    StorageConfig config,
    String remotePath, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    Future<String?> run() async {
      RemoteStorage? storage;
      try {
        storage = create(config);
        await storage.open();
        await storage.delete(remotePath);
        return null;
      } on RemoteException catch (e) {
        return e.message;
      } catch (e) {
        return '删除失败：$e';
      } finally {
        if (storage != null) {
          try {
            await storage.close();
          } catch (_) {
            // 忽略
          }
        }
      }
    }

    try {
      return await Isolate.run(run).timeout(
        timeout,
        onTimeout: () => '删除超时：服务器在 ${timeout.inSeconds} 秒内没有响应',
      );
    } catch (e) {
      return '删除失败：$e';
    }
  }
}
