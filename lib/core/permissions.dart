import 'package:permission_handler/permission_handler.dart';

import 'app_log.dart';

enum MediaAccess { granted, denied, permanentlyDenied }

/// 申请读取照片与发通知的权限。
///
/// Android 13 起用 READ_MEDIA_IMAGES，之前的版本回落到存储权限；
/// 通知权限只在 Android 13+ 存在，用于前台服务与上传完成通知。
Future<MediaAccess> ensureMediaAccess() async {
  try {
    final photos = Permission.photos;
    var status = await photos.status;
    if (!status.isGranted && !status.isLimited) {
      status = await photos.request();
    }
    if (status.isGranted || status.isLimited) return MediaAccess.granted;
    if (status.isPermanentlyDenied) return MediaAccess.permanentlyDenied;

    // Android 12 及以下：READ_EXTERNAL_STORAGE。
    final storage = Permission.storage;
    var storageStatus = await storage.status;
    if (!storageStatus.isGranted) {
      storageStatus = await storage.request();
    }
    if (storageStatus.isGranted || storageStatus.isLimited) {
      return MediaAccess.granted;
    }
    if (storageStatus.isPermanentlyDenied) {
      return MediaAccess.permanentlyDenied;
    }
    return MediaAccess.denied;
  } catch (error) {
    AppLog.instance.warn('permission', '申请照片权限失败：$error');
    return MediaAccess.denied;
  }
}

Future<void> requestNotificationPermission() async {
  try {
    final status = await Permission.notification.status;
    if (!status.isGranted) {
      await Permission.notification.request();
    }
  } catch (error) {
    AppLog.instance.warn('permission', '申请通知权限失败：$error');
  }
}

Future<void> openSystemSettings() async {
  await openAppSettings();
}
