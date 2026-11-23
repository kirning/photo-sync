# 更新日志

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
