import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../models/storage_config.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';

class StorageDetailScreen extends StatefulWidget {
  const StorageDetailScreen({super.key, required this.storageId});

  final String storageId;

  @override
  State<StorageDetailScreen> createState() => _StorageDetailScreenState();
}

class _StorageDetailScreenState extends State<StorageDetailScreen> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _deleting = {};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _delete(
    AppState state,
    StorageConfig storage,
    UploadedRecord record,
  ) async {
    final ok = await confirmAction(
      context,
      title: '删除云端照片',
      message: '将从「${storage.name}」删除这条照片的云端副本，本地照片不受影响。\n\n'
          '${record.remotePath}',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _deleting.add(record.path));
    final error = await state.deleteRemoteFile(storage, record);
    if (!mounted) return;
    setState(() => _deleting.remove(record.path));
    if (error != null) {
      showMessage(context, '删除失败：$error', error: true);
    } else {
      showMessage(context, '已删除云端副本');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final storage = state.storageById(widget.storageId);
    if (storage == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('存储')),
        body: const EmptyState(
          icon: Icons.cloud_off_outlined,
          title: '存储服务已被删除',
        ),
      );
    }
    final all = state.uploadsOf(storage.id);
    final query = _search.text.trim().toLowerCase();
    final records = query.isEmpty
        ? all
        : all
            .where((record) =>
                record.path.toLowerCase().contains(query) ||
                record.remotePath.toLowerCase().contains(query))
            .toList();
    final totalBytes = all.fold<int>(0, (sum, record) => sum + record.size);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('${storage.name} · 已上传'),
        actions: [
          IconButton(
            tooltip: '测试连接',
            onPressed: () async {
              final error = await state.testStorage(storage);
              if (!context.mounted) return;
              if (error != null) {
                showMessage(context, '连接失败：$error', error: true);
              } else {
                showMessage(context, '连接成功');
              }
            },
            icon: const Icon(Icons.wifi_tethering),
          ),
        ],
      ),
      body: all.isEmpty
          ? const EmptyState(
              icon: Icons.cloud_upload_outlined,
              title: '还没有上传记录',
              message: '在相册里选择照片并上传后，这里会显示已上传的云端副本。',
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_done_outlined,
                          size: 16, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text('${all.length} 张 · ${Fmt.bytes(totalBytes)}',
                          style: Theme.of(context).textTheme.labelLarge),
                      const Spacer(),
                      Text(
                        storage.type.label,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: '搜索文件名或远端路径',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(_search.clear),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: records.isEmpty
                      ? const EmptyState(
                          icon: Icons.search_off,
                          title: '没有匹配的记录',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          itemCount: records.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final record = records[index];
                            return Card(
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                leading: _Thumb(path: record.path),
                                title: Text(
                                  record.remotePath.split('/').last,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${record.remotePath}\n上传于 ${Fmt.dateTime(record.uploadedAt)}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                isThreeLine: true,
                                trailing: _deleting.contains(record.path)
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : IconButton(
                                        tooltip: '删除云端副本',
                                        icon: Icon(Icons.delete_outline,
                                            color: scheme.error),
                                        onPressed: () =>
                                            _delete(state, storage, record),
                                      ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: 160,
          errorBuilder: (_, __, ___) => Container(
            color: scheme.surfaceContainerHighest,
            child: Icon(Icons.image_not_supported_outlined,
                size: 20, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}
