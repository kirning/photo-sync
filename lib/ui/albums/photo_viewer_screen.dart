import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../models/album.dart';
import '../../models/storage_config.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';

class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.files,
    required this.initialIndex,
  });

  final List<MediaFile> files;
  final int initialIndex;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  MediaFile get _current => widget.files[_index];

  Future<void> _showInfo() async {
    final state = context.read<AppState>();
    final file = _current;
    final storages = state.storages;
    final entries = <(StorageConfig, UploadedRecord)>[];
    for (final storage in storages) {
      final record = state.uploadedRecord(file.path, storage.id);
      if (record != null) entries.add((storage, record));
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.titleLarge),
              const SizedBox(height: 10),
              _InfoRow(label: '大小', value: Fmt.bytes(file.size)),
              _InfoRow(
                label: '修改时间',
                value: Fmt.dateTime(
                  DateTime.fromMillisecondsSinceEpoch(file.modifiedMs),
                ),
              ),
              _InfoRow(label: '本地路径', value: file.path, selectable: true),
              const SizedBox(height: 12),
              Text('云端副本', style: Theme.of(sheetContext).textTheme.titleSmall),
              const SizedBox(height: 6),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    '这张照片还没有上传到任何存储',
                    style: Theme.of(sheetContext)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                          color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                        ),
                  ),
                )
              else
                for (final entry in entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(entry.$1.type.icon),
                    title: Text(entry.$1.name),
                    subtitle: Text(
                      '${entry.$2.remotePath}\n上传于 ${Fmt.dateTime(entry.$2.uploadedAt)}',
                    ),
                    isThreeLine: true,
                    trailing: IconButton(
                      tooltip: '删除云端副本',
                      icon: Icon(
                        Icons.delete_outline,
                        color: Theme.of(sheetContext).colorScheme.error,
                      ),
                      onPressed: () async {
                        Navigator.of(sheetContext).pop();
                        await _deleteRemote(state, entry.$1, entry.$2);
                      },
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteRemote(
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
    final error = await state.deleteRemoteFile(storage, record);
    if (!mounted) return;
    if (error != null) {
      showMessage(context, '删除失败：$error', error: true);
    } else {
      showMessage(context, '已删除云端副本');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final uploaded = state.uploadedStoragesFor(_current.path);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} / ${widget.files.length}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: '详情',
            onPressed: _showInfo,
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.files.length,
              onPageChanged: (value) => setState(() => _index = value),
              itemBuilder: (context, index) {
                final file = widget.files[index];
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: Image.file(
                      File(file.path),
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image_outlined,
                                color: Colors.white54, size: 48),
                            SizedBox(height: 12),
                            Text('无法加载图片',
                                style: TextStyle(color: Colors.white54)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _current.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${Fmt.bytes(_current.size)} · '
                        '${Fmt.dateTime(DateTime.fromMillisecondsSinceEpoch(_current.modifiedMs))}',
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (uploaded.isNotEmpty)
                  const Icon(Icons.cloud_done, color: Colors.greenAccent, size: 20),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.selectable = false});

  final String label;
  final String value;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(label, style: style)),
          Expanded(
            child: selectable
                ? SelectableText(value, style: style)
                : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}
