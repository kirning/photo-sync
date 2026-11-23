package com.kirning.photo_sync

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
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
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installCrashHandler()
        super.onCreate(savedInstanceState)
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
