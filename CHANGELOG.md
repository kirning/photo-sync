# 更新日志

## 0.2.2

修复「上传任务卡在 0/1 · 0.0% · 0 B 不动」的问题，并补齐日志能力。

- 根因：`flutter_background_service` 用 `Pipe.invoke()` 把 `runJob` 事件投递给后台 isolate，而 `Pipe` 在没有监听者时会**静默丢弃**消息（插件源码 `Pipe.java`：`if (!listeners.isEmpty())` 才投递）。冷启动后台服务要 1~2 秒才注册监听，UI 之前的两次重发（0ms / 600ms）可能都落在这个空窗里，任务于是永远不会开始：界面上的「上传中 0%」只是 UI 本地创建的记录。
- 修复 1（后台自驱）：后台 isolate 启动后不再等消息，直接用自己的目录（`path_provider`）扫 `jobs/*.spec.json`，把状态为「等待中/上传中」的任务捡回来执行；每次收到 `runJob` 也会顺手扫盘。服务空闲关闭前再扫一次，避免空窗期漏任务。
- 修复 2（UI 侧确认）：入队时重试通知直到后台写出 `status.json` 为止（最多 6 秒），并把这个结果带回任务提示。
- 修复 3（自愈）：任务列表每 2 秒刷新时，若发现任务没有状态文件，20 秒后自动重新通知后台服务；超过 5 分钟仍无响应则标记失败并说明原因，不再无限「上传中」。
- 修复 4（超时）：连接存储服务 60 秒超时即失败；单文件上传 120 秒没有字节进度即中断该文件，避免半开连接把任务吊死。
- 任务卡片直接显示当前阶段原因（正在连接存储服务… / 等待 Wi-Fi 网络… / 正在准备上传…）。
- 日志：`AppLog` 现在同时写文件（`logs/app.log`，512 KB 轮转）与 logcat；设置 → 运行日志新增「导出日志」，可把历史日志 + 崩溃记录一起导出到手机存储。

## 0.2.1

修复上传时的闪退（崩溃循环）问题。

- 根因：后台上传用的前台服务在 `startForeground` 时使用的通知渠道 `photo_sync_upload` 从未创建过。`flutter_background_service` 只在「没有显式指定渠道 id」时才自动建渠道（插件源码 `BackgroundService.java:89-95`），而我们显式传了渠道 id，于是渠道不存在，系统抛 `RemoteServiceException$CannotPostForegroundServiceNotificationException: Bad notification for startForeground` 直接崩溃；随后 Watchdog 每 5 秒把服务拉起一次，形成崩溃循环。这与 WebDAV / SMB / S3 的具体存储类型无关，任何上传都会触发。
- 修复：新增 `PhotoSyncApplication`，在 `Application.onCreate()` 里创建「上传任务」通知渠道（IMPORTANCE_LOW、不显示角标），保证进程无论怎么被拉起，`startForeground` 之前渠道都已存在。
- 崩溃记录里如果还能看到这条 `Bad notification for startForeground`，说明装的是旧版本，请升级到 0.2.1 及以上。

## 0.2.0

- 自动更新：在「关于」页检查 GitHub Releases 上的最新版本，直接下载对应架构的 APK 并调起系统安装器；设置里可开关「启动时检查更新」。
- 按内容哈希去重：上传前计算（并缓存）照片的 SHA-256，同一张照片即使换了目录、改了名字也不会重复上传；已上传索引同时记录哈希。
- 「忽略小于」增加自定义输入：预设 0 / 10KB / 50KB / 100KB 之外，可自己填任意大小（0～100MB）。
- 存储连接测试与云端删除改到独立 isolate 执行，弱网时不再卡住界面（90 秒超时给中文提示）。

## 0.1.1

排查闪退问题的诊断版本。

- 新增崩溃记录：Dart 未捕获异常写入 `crash.log`，Android 原生异常写入 `native_crash.log`，都放在应用私有目录。
- 「运行日志」页顶部会提示「检测到上次运行异常」，可查看、复制或导出崩溃记录到手机存储（Android/data/com.kirning.photo_sync/files/crash-logs）。
- 「复制全部」现在会把崩溃记录一并复制。
- 其余功能与 0.1.0 一致。

## 0.1.0

首个可用版本。

### 功能

- 自动发现 Android 常见照片目录（DCIM、Camera、Screenshots、Pictures、Download、微信 / WhatsApp / Telegram 等），也支持手动选择或直接输入目录路径，每个目录即一本相册。
- 存储服务配置：WebDAV（含 Nextcloud / 坚果云 / Alist）、SMB 2/3（Windows 共享、NAS）、S3 兼容（AWS S3、MinIO、R2、OSS 等，自实现 SigV4）。
- 整本相册或多选照片上传，可选目标存储；上传前显示每本存储的已上传数量。
- 已上传标记：照片右上角云朵角标 + 相册内「已上传 N 张」统计，索引持久化在本地。
- 云端删除：在存储详情里查看已上传文件并删除远端副本，成功后同步清除本地标记。
- 后台上传：前台服务 + 独立 isolate，支持进度通知、暂停、继续、取消；服务重启后自动恢复未完成任务。
- 网络策略：仅 Wi-Fi 或 Wi-Fi + 移动数据；仅 Wi-Fi 且未连接 Wi-Fi 时任务自动暂停等待。
- 远端目录模板：`{album} / {yyyy} / {MM} / {dd} / {HH} / {mm}`，默认按相册和年月归档。
- 重名保护：远端同名且大小一致视为已存在直接跳过，大小不同自动追加 `(1)` 后缀。
- 内置运行日志与连接测试，方便排查认证与网络问题。

### 构建

- GitHub Actions 在 push、PR、`v*` 标签时执行 analyze / test 并构建分 ABI 的 release APK。
- 打标签时自动创建 Release 并附上 APK。
