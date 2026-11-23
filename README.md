# 照片同步 Photo Sync

[![Build APK](https://github.com/kirning/photo-sync/actions/workflows/build.yml/badge.svg)](https://github.com/kirning/photo-sync/actions/workflows/build.yml)

一款 Flutter 编写的 Android 相册云同步工具：自动发现手机里的照片目录，把整本相册或有选择的照片上传到 **WebDAV / SMB / S3** 存储，上传过程在后台前台服务里跑，已上传的照片有明确标记，也能直接删除云端的副本。

当前版本：**0.1.0**（首个可用版本）

## 功能

- **相册发现**：启动时自动识别 `DCIM`、`DCIM/Camera`、`Pictures`、`Pictures/Screenshots`、`Download`、微信/WhatsApp/Telegram 等常见目录；也可手动添加任意目录作为相册。
- **三种存储服务**
  - WebDAV：Nextcloud、坚果云、群晖 WebDAV、Alist 等（Basic 认证，可上传到子目录）
  - SMB：Windows 共享、NAS（SMB 2/3，可填域名、共享名、子目录）
  - S3 兼容：AWS S3、MinIO、Cloudflare R2、阿里云 OSS 的 S3 接口等（自实现 SigV4 签名，支持自定义 Endpoint、Path-Style、会话令牌）
- **整本相册 / 多选上传**：相册页可一键上传全部，也可进入网格多选后上传；上传前选择目标存储。
- **已上传标记**：照片右上角云朵角标、相册页的「已上传 N 张」统计，都来自本地上传索引，换个网络、重启应用也不会丢。
- **云端删除**：在存储详情里按需删除远端文件，删除成功同步移除本地标记。
- **后台上传**：基于前台服务 + 独立 isolate，退到后台、锁屏也继续跑；带有进度通知，可暂停 / 继续 / 取消，进程被杀后重启会自动恢复未完成的任务。
- **网络策略**：可选择「仅 Wi-Fi 上传」或「Wi-Fi 与移动数据都允许」；仅 Wi-Fi 时，没有 Wi-Fi 会自动暂停等待，连上 Wi-Fi 后继续。
- **目录模板**：远端目录支持 `{album}`、`{yyyy}`、`{MM}`、`{dd}`、`{HH}`、`{mm}` 占位符，默认按 `相册名/年/月` 归档。
- **重名与去重**：远端同名文件大小一致则跳过（视为已上传），大小不同自动追加 `(1)` 后缀，绝不覆盖用户已有文件。
- **运行日志**：内置日志页，方便排查网络与认证问题。

## 界面

| 相册 | 照片网格 | 存储服务 | 上传任务 | 设置 |
| --- | --- | --- | --- | --- |
| 自动发现 + 手动添加 | 多选上传、已上传角标 | WebDAV / SMB / S3 | 进度、暂停、取消 | 网络策略、模板、扫描规则 |

## 构建

环境要求：

- Flutter **3.50.1**（stable）
- JDK 17
- Android SDK：compileSdk 37（`permission_handler` 13.x 的要求），build-tools 36+
- 不需要安装 NDK：`android/app/build.gradle.kts` 里显式固定了 `ndkVersion = "26.1.10909125"`，插件对 NDK 28.2 的提示只是警告

> 依赖里 `file_picker` 固定在 8.x、`flutter_plugin_android_lifecycle` 固定在 2.0.24、`path_provider_android` 固定在 2.2.x：新版本会把 `jni` 插件带进来，从而强制要求 NDK 与更高的 compileSdk，插件之间容易互相打架。升级前请先在本机跑通 release 构建。

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi
```

产物位于 `build/app/outputs/flutter-apk/`：

- `app-arm64-v8a-release.apk`（绝大多数手机）
- `app-armeabi-v7a-release.apk`（老设备）
- `app-x86_64-release.apk`（模拟器）

### GitHub Actions

`.github/workflows/build.yml` 会在 push 到 `main`、提 PR、以及打 `v*` 标签时运行：先 analyze + test，再构建分 ABI 的 release APK 并作为 artifact 上传；打标签时还会自动创建 Release 并附上 APK。

发版：

```bash
git tag v0.1.0
git push origin v0.1.0
```

## 存储配置示例

### WebDAV（坚果云）

- 地址：`https://dav.jianguoyun.com/dav/`
- 用户名：坚果云账号邮箱
- 密码：第三方应用密码（不是登录密码）
- 子目录：可留空，或 `photo-sync`

### SMB（Windows 共享）

- 主机：`192.168.1.10`
- 共享名：`photo`
- 用户名 / 密码：Windows 账号；域可留空，或填 `WORKGROUP` / `MicrosoftAccount`
- 子目录：`备份/手机`

### S3（MinIO 示例）

- Endpoint：`http://192.168.1.10:9000`（不带路径）
- Region：`us-east-1`
- Bucket：`photo`
- Access Key / Secret Key：MinIO 控制台里的密钥
- Path-Style：开启（MinIO 必需）

## 数据与隐私

- 所有配置与索引都保存在应用私有目录（`getApplicationSupportDirectory`）：`albums.json`、`storages.json`、`settings.json`、`jobs/`、`uploads/`。
- 照片只在本机读取并上传到你自己配置的存储，应用不上传任何统计与诊断数据。
- 存储密码保存在应用私有目录的 JSON 中，不会发送到其他位置；卸载应用即清除。

## 项目结构

```
lib/
  core/        日志、格式化、原子 JSON 读写、远端路径规则、权限、版本信息
  data/        应用目录布局与仓库（相册/存储/任务/上传索引）
  models/      相册、存储配置、上传任务、设置
  remote/      RemoteStorage 抽象 + WebDAV / SMB / S3 实现、SigV4 签名
  services/    媒体扫描、上传执行器（可跑在 isolate）、前台服务
  state/       AppState（provider）
  ui/          相册、存储、任务、设置、日志、关于
```

## 已知限制

- 仅支持 Android（iOS 端未做适配）。
- 加密相册、HEIC 解码依赖系统能力，部分机型可能无法预览。
- 上传是「一次性任务」模型：任务完成后再次上传同一张照片会被索引跳过；如需重传，可在设置里重置上传标记。

## 排查问题

应用会把异常记录在私有目录，下次启动时可以在「设置 → 运行日志」看到提示，点开后能查看、复制或导出崩溃记录（导出位置：`Android/data/com.kirning.photo_sync/files/crash-logs/`）。

如果应用直接闪退、来不及记录，可以用电脑抓日志：

```bash
adb logcat -c
# 在手机上复现问题，然后
adb logcat -d > logcat.txt
# 只看本应用相关的崩溃
adb logcat -d | grep -E "FATAL|AndroidRuntime|photo_sync|flutter"
```

## License

MIT
