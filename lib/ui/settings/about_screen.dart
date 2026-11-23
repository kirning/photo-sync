import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../core/formatters.dart';
import '../../services/update_service.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';

/// 关于页：版本信息 + 从 GitHub Releases 检查/下载/安装更新。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  bool _downloading = false;
  int _received = 0;
  int _total = 0;
  File? _downloadedFile;
  String? _error;

  Future<void> _check(AppState state) async {
    setState(() => _error = null);
    await state.checkForUpdate();
    if (!mounted) return;
    final error = state.updateError;
    if (error != null) {
      setState(() => _error = error);
    } else if (state.availableUpdate == null) {
      showMessage(context, '已是最新版本 ${AppInfo.versionLabel}');
    } else {
      setState(() => _downloadedFile = null);
    }
  }

  Future<void> _download(AppState state, UpdateInfo info) async {
    setState(() {
      _downloading = true;
      _received = 0;
      _total = info.size;
      _error = null;
    });
    try {
      final file = await UpdateService.download(
        info,
        state.paths.updatesDir,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloadedFile = file;
        _downloading = false;
      });
      await _install(file);
    } on UpdateException catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _install(File apk) async {
    try {
      await UpdateService.installApk(apk);
    } on UpdateException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
      showMessage(context, error.message, error: true);
    }
  }

  Future<void> _showNotes(UpdateInfo info) async {
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('新版本 ${info.version}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              info.notes.isEmpty ? '该版本没有提供更新说明。' : info.notes,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: info.pageUrl));
              messenger.showSnackBar(const SnackBar(content: Text('发布页地址已复制')));
            },
            child: const Text('复制发布页'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final update = state.availableUpdate;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.photo_library_outlined,
                  size: 44, color: scheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              AppInfo.appName,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '版本 ${AppInfo.versionLabel}',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '版本更新',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (state.checkingUpdate)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        TextButton.icon(
                          onPressed: () => _check(state),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('检查更新'),
                        ),
                    ],
                  ),
                  if (update != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '发现新版本 ${update.version}',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: scheme.primary),
                    ),
                    if (update.notes.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        update.notes.length > 400
                            ? '${update.notes.substring(0, 400)}…'
                            : update.notes,
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_downloading)
                          SizedBox(
                            width: 220,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                LinearProgressIndicator(
                                  value: _total > 0 ? _received / _total : null,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _total > 0
                                      ? '${Fmt.bytes(_received)} / ${Fmt.bytes(_total)}'
                                      : '正在下载 ${Fmt.bytes(_received)}',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ),
                          )
                        else if (_downloadedFile != null)
                          FilledButton.icon(
                            onPressed: () => _install(_downloadedFile!),
                            icon: const Icon(Icons.system_update_alt),
                            label: const Text('立即安装'),
                          )
                        else
                          FilledButton.icon(
                            onPressed: update.hasApk
                                ? () => _download(state, update)
                                : null,
                            icon: const Icon(Icons.download),
                            label: Text(update.hasApk ? '下载并安装' : '该版本没有安装包'),
                          ),
                        TextButton(
                          onPressed: () => _showNotes(update),
                          child: const Text('更新说明'),
                        ),
                      ],
                    ),
                    Text(
                      '首次安装需要允许「安装未知应用」；下载完成后系统会弹出安装界面。',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  ],
                  if (state.lastUpdateCheck != null)
                    Text(
                      '上次检查：${Fmt.relative(state.lastUpdateCheck!)}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('功能', style: TextStyle(fontWeight: FontWeight.w600)),
                  SizedBox(height: 8),
                  Text('· 浏览手机里的照片目录，手动添加任意目录作为相册\n'
                      '· 支持 WebDAV、SMB、S3 兼容对象存储\n'
                      '· 按相册上传，按「相册/年/月」分目录存放\n'
                      '· 已上传的照片带云端标识，可单独删除云端副本\n'
                      '· 按内容哈希去重，同一张照片不会重复上传\n'
                      '· 上传在前台服务中进行，可暂停/继续/取消\n'
                      '· 可选择仅在 Wi-Fi 下上传\n'
                      '· 可直接从 GitHub Releases 检查并安装新版本'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('源代码'),
                  subtitle: Text(AppInfo.repository),
                  trailing: IconButton(
                    tooltip: '复制地址',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: AppInfo.repository),
                      );
                      if (context.mounted) showMessage(context, '地址已复制');
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('数据目录'),
                  subtitle: Text(
                    '相册、存储配置与上传记录都保存在应用私有目录，'
                    '卸载应用会一并删除。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '照片只在你选择的设备与云服务之间传输，\n应用没有任何第三方统计或上传。',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
