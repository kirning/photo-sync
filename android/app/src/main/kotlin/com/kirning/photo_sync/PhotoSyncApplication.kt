package com.kirning.photo_sync

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build

/**
 * 应用入口。
 *
 * 这里只建「上传任务」通知渠道，原因是 flutter_background_service 的
 * BackgroundService.onCreate() 只在 notificationChannelId 为空时才创建渠道
 * （见插件源码 BackgroundService.java:89-95）。我们在 Dart 侧显式传了渠道 id
 * （photo_sync_upload），插件就会跳过创建；startForeground 时渠道不存在，
 * 系统会抛 RemoteServiceException$CannotPostForegroundServiceNotificationException
 * 「Bad notification for startForeground」，进程直接崩溃，且被 Watchdog 每 5 秒
 * 拉起一次，形成崩溃循环。
 *
 * 渠道在 Application.onCreate 中创建，保证无论进程是点图标启动、还是被
 * WatchdogReceiver / BootReceiver 拉起，startForeground 之前渠道一定已存在。
 * 注意：渠道 id 必须与 lib/services/background_service.dart 中的
 * uploadNotificationChannelId 保持一致。
 */
class PhotoSyncApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        ensureUploadChannel()
    }

    private fun ensureUploadChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // 已经存在就不要再创建，避免覆盖用户手动改过的通知设置。
        if (manager.getNotificationChannel(CHANNEL_ID) != null) {
            return
        }
        val channel = NotificationChannel(
            CHANNEL_ID,
            "上传任务",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "相册上传进度"
        channel.setShowBadge(false)
        channel.lockscreenVisibility = android.app.Notification.VISIBILITY_SECRET
        manager.createNotificationChannel(channel)
    }

    companion object {
        /** 与 Dart 侧 uploadNotificationChannelId 一致。 */
        const val CHANNEL_ID = "photo_sync_upload"
    }
}
