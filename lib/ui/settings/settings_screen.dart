import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../core/formatters.dart';
import '../../core/remote_path.dart';
import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';
import 'about_screen.dart';
import 'logs_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _update(AppState state, void Function(AppSettings next) change) async {
    final next = state.settings.copy();
    change(next);
    await state.saveSettings(next);
  }

  Future<void> _editTemplate(BuildContext context, AppState state) async {
    final controller = TextEditingController(text: state.settings.folderTemplate);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('远端目录模板'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: '模板'),
            ),
            const SizedBox(height: 12),
            Text(
              '可用变量：\n'
              '{album} 相册名\n'
              '{yyyy} 年份、{MM} 月份、{dd} 日期\n'
              '{HH} 时、{mm} 分\n\n'
              '例如 {album}/{yyyy}/{MM} 会把 2024 年 5 月的照片放到 '
              '相册名/2024/05 下。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null || !context.mounted) return;
    final template = result.isEmpty ? RemotePathUtil.defaultFolderTemplate : result;
    await _update(state, (next) => next.folderTemplate = template);
  }

  Future<void> _resetIndex(BuildContext context, AppState state) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('重置上传标记'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('all'),
            child: const Text('全部存储'),
          ),
          for (final storage in state.storages)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(storage.id),
              child: Text(storage.name),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    final ok = await confirmAction(
      context,
      title: '确认重置',
      message: '重置后这些照片会重新显示为“未上传”，'
          '但云端已有的文件不会删除，也不会自动重新上传。',
      confirmLabel: '重置',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await state.resetUploadIndex(choice == 'all' ? null : choice);
    if (context.mounted) showMessage(context, '已重置上传标记');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final settings = state.settings;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _SectionHeader(
            title: '上传网络',
            subtitle: '当前：${state.networkLabel}',
          ),
          RadioGroup<NetworkPolicy>(
            groupValue: settings.networkPolicy,
            onChanged: (value) {
              if (value == null) return;
              _update(state, (next) => next.networkPolicy = value);
            },
            child: Column(
              children: [
                for (final policy in NetworkPolicy.values)
                  RadioListTile<NetworkPolicy>(
                    value: policy,
                    title: Text(policy.label),
                    subtitle: Text(policy.description),
                  ),
              ],
            ),
          ),
          const Divider(),
          _SectionHeader(title: '上传'),
          ListTile(
            title: const Text('并发上传数'),
            subtitle: Text('${settings.concurrency} 个文件同时上传'),
            trailing: SizedBox(
              width: 160,
              child: Slider(
                value: settings.concurrency.toDouble(),
                min: 1,
                max: 4,
                divisions: 3,
                label: '${settings.concurrency}',
                onChanged: (value) => _update(
                  state,
                  (next) => next.concurrency = value.round(),
                ),
              ),
            ),
          ),
          ListTile(
            title: const Text('远端目录模板'),
            subtitle: Text(settings.folderTemplate),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _editTemplate(context, state),
          ),
          SwitchListTile(
            title: const Text('完成后发送通知'),
            value: settings.notifyOnComplete,
            onChanged: (value) =>
                _update(state, (next) => next.notifyOnComplete = value),
          ),
          SwitchListTile(
            title: const Text('启动时自动扫描相册'),
            value: settings.autoScanOnStart,
            onChanged: (value) =>
                _update(state, (next) => next.autoScanOnStart = value),
          ),
          const Divider(),
          _SectionHeader(title: '扫描'),
          ListTile(
            title: const Text('忽略小于指定大小的文件'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final option in const [0, 10 * 1024, 50 * 1024, 100 * 1024])
                    ChoiceChip(
                      label: Text(option == 0 ? '不忽略' : Fmt.bytes(option)),
                      selected: settings.minImageBytes == option,
                      onSelected: (_) => _update(
                        state,
                        (next) => next.minImageBytes = option,
                      ),
                    ),
                ],
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('跳过隐藏文件/目录'),
            value: settings.skipHidden,
            onChanged: (value) =>
                _update(state, (next) => next.skipHidden = value),
          ),
          const Divider(),
          _SectionHeader(title: '数据'),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('重置上传标记'),
            subtitle: const Text('让已上传的照片重新显示为未上传'),
            onTap: () => _resetIndex(context, state),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('运行日志'),
            subtitle: const Text('排查上传问题时可查看'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LogsScreen()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于'),
            subtitle: Text('${AppInfo.appName} ${AppInfo.versionLabel}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '${AppInfo.appName} ${AppInfo.versionLabel}',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
