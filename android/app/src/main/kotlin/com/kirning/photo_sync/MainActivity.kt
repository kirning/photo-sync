package com.kirning.photo_sync

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 除了 Flutter 侧的异常捕获，这里再把 Android 原生层的未捕获异常写进
 * filesDir/native_crash.log，方便用户在下一次启动时从「运行日志」页取走。
 *
 * 原生崩溃（例如前台服务启动失败、JNI 异常）不会经过 Dart 的 onError，
 * 只能靠默认 UncaughtExceptionHandler 记录，然后继续交给系统处理进程退出。
 *
 * 另外通过 `photo_sync/install` 通道提供两个能力：
 * - deviceAbi：返回设备首选 ABI，用于挑选对应架构的 APK；
 * - installApk：把下载好的 APK 交给系统安装器（经由 FileProvider 授权）。
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installCrashHandler()
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "photo_sync/install")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "deviceAbi" -> {
                        result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "")
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "缺少安装包路径", null)
                        } else {
                            try {
                                installApk(File(path))
                                result.success(true)
                            } catch (error: Exception) {
                                result.error("install_failed", error.message ?: "无法启动安装程序", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(file: File) {
        if (!file.exists()) {
            throw IllegalStateException("安装包不存在，请重新下载")
        }
        val uri: Uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun installCrashHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeCrash(thread, throwable)
            } catch (_: Throwable) {
                // 记录失败时不能影响系统原本的崩溃流程。
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    private fun writeCrash(thread: Thread, throwable: Throwable) {
        val buffer = StringWriter()
        throwable.printStackTrace(PrintWriter(buffer))
        val stamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())
        val text = "===== $stamp [android:${thread.name}] =====\n$buffer\n"
        File(filesDir, "native_crash.log").appendText(text)
    }
}
