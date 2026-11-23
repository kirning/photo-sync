import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../models/storage_config.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';
import 'storage_detail_screen.dart';
import 'storage_form_screen.dart';

class StoragesScreen extends StatelessWidget {
  const StoragesScreen({super.key});

  Future<void> _openForm(BuildContext context, [StorageConfig? config]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StorageFormScreen(config: config),
      ),
    );
  }

  Future<void> _test(BuildContext context, AppState state, StorageConfig config) async {
    showMessage(context, '正在测试「${config.name}」…');
    final error = await state.testStorage(config);
    if (!context.mounted) return;
    if (error != null) {
      showMessage(context, '连接失败：$error', error: true);
    } else {
      showMessage(context, '「${config.name}」连接成功');
    }
  }

  Future<void> _delete(BuildContext context, AppState state, StorageConfig config) async {
    final ok = await confirmAction(
      context,
      title: '删除存储服务',
      message: '将删除「${config.name}」的配置和本地的上传记录，'
          '已上传到云端的照片不会被删除。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    await state.deleteStorage(config);
    if (context.mounted) showMessage(context, '已删除「${config.name}」');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final storages = state.storages;
    return Scaffold(
      appBar: AppBar(
        title: const Text('存储服务'),
        actions: [
          IconButton(
            tooltip: '支持的类型',
            onPressed: () => _showHelp(context),
            icon: const Icon(Icons.help_outline),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context),
        icon: const Icon(Icons.add),
        label: const Text('添加服务'),
      ),
      body: storages.isEmpty
          ? EmptyState(
              icon: Icons.cloud_outlined,
              title: '还没有存储服务',
              message: '支持 WebDAV、SMB（局域网共享）和 S3 兼容对象存储。\n'
                  '添加后即可把相册照片上传到云端。',
              action: FilledButton.icon(
                onPressed: () => _openForm(context),
                icon: const Icon(Icons.add),
                label: const Text('添加存储服务'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: storages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final config = storages[index];
                return _StorageCard(
                  config: config,
                  uploadCount: state.uploadCountFor(config.id),
                  testing: state.isTestingStorage(config.id),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => StorageDetailScreen(storageId: config.id),
                    ),
                  ),
                  onTest: () => _test(context, state, config),
                  onEdit: () => _openForm(context, config),
                  onUploads: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => StorageDetailScreen(storageId: config.id),
                    ),
                  ),
                  onDelete: () => _delete(context, state, config),
                );
              },
            ),
    );
  }

  void _showHelp(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('支持的存储类型', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final type in StorageType.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(type.icon),
                  title: Text(type.label),
                  subtitle: Text(type.description),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({
    required this.config,
    required this.uploadCount,
    required this.testing,
    required this.onTap,
    required this.onTest,
    required this.onEdit,
    required this.onUploads,
    required this.onDelete,
  });

  final StorageConfig config;
  final int uploadCount;
  final bool testing;
  final VoidCallback onTap;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onUploads;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = config.lastTestOk;
    final statusColor = testing
        ? scheme.onSurfaceVariant
        : ok == null
            ? scheme.onSurfaceVariant
            : ok
                ? const Color(0xFF2E7D32)
                : scheme.error;
    final statusText = testing
        ? '正在测试…'
        : config.lastTestMessage?.isNotEmpty == true
            ? config.lastTestMessage!
            : '尚未测试连接';

    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(config.type.icon, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            config.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          config.type.label,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.cloud_done_outlined,
                            size: 14, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          '已上传 $uploadCount 张',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        if (!config.enabled) ...[
                          const SizedBox(width: 10),
                          Text(
                            '已停用',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: scheme.outline),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      statusText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: statusColor),
                    ),
                    if (config.lastTestAt != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        Fmt.relative(config.lastTestAt!),
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              if (testing)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    switch (value) {
                      case 'test':
                        onTest();
                      case 'edit':
                        onEdit();
                      case 'uploads':
                        onUploads();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'test', child: Text('测试连接')),
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'uploads', child: Text('已上传照片')),
                    PopupMenuItem(value: 'delete', child: Text('删除服务')),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
