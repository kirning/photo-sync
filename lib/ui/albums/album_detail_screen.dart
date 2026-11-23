import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../models/album.dart';
import '../../models/settings.dart';
import '../../models/storage_config.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';
import 'photo_viewer_screen.dart';

class AlbumDetailScreen extends StatefulWidget {
  const AlbumDetailScreen({super.key, required this.albumId});

  final String albumId;

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final Set<String> _selected = {};
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      final album = state.albumById(widget.albumId);
      if (album == null) return;
      if (state.filesFor(album.id).isEmpty && !state.isScanning(album.id)) {
        state.scanAlbum(album);
      }
    });
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _openViewer(List<MediaFile> files, int index) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewerScreen(
          files: files,
          initialIndex: index,
        ),
      ),
    );
  }

  List<MediaFile> _uploadTargets(List<MediaFile> files) {
    if (_selected.isEmpty) return files;
    return files.where((file) => _selected.contains(file.path)).toList();
  }

  Future<void> _upload(AppState state, Album album, List<MediaFile> files) async {
    final targets = _uploadTargets(files);
    if (targets.isEmpty) {
      showMessage(context, '请先选择照片');
      return;
    }
    final enabled = state.storages.where((storage) => storage.enabled).toList();
    if (enabled.isEmpty) {
      showMessage(context, '还没有可用的存储服务，请先在「存储」中添加', error: true);
      return;
    }
    final already = targets
        .where((file) => state.uploadedStoragesFor(file.path).isNotEmpty)
        .length;
    final storage = await showModalBottomSheet<StorageConfig>(
      context: context,
      showDragHandle: true,
      builder: (context) => _StoragePicker(
        storages: enabled,
        count: targets.length,
        alreadyCount: already,
        warnWifi: state.settings.networkPolicy == NetworkPolicy.wifiOnly &&
            !state.onWifi,
        uploadedCountOf: state.uploadCountFor,
      ),
    );
    if (storage == null || !mounted) return;

    setState(() => _starting = true);
    final result = await state.startUpload(
      storage: storage,
      albumName: album.name,
      files: targets,
    );
    if (!mounted) return;
    setState(() => _starting = false);
    if (result.error != null) {
      showMessage(context, result.error!, error: true);
      return;
    }
    _clearSelection();
    final skipped = result.skipped > 0 ? '，跳过 ${result.skipped} 张已上传' : '';
    showMessage(context, '已加入后台上传队列：${result.queued} 张$skipped');
  }

  Future<void> _removeAlbum(AppState state, Album album) async {
    final ok = await confirmAction(
      context,
      title: '移除相册',
      message: '仅从应用中移除「${album.name}」，不会删除手机上的照片。',
      confirmLabel: '移除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await state.removeAlbum(album);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final album = state.albumById(widget.albumId);
    if (album == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('相册')),
        body: const EmptyState(
          icon: Icons.photo_library_outlined,
          title: '相册已不存在',
          message: '它可能已被移除。',
        ),
      );
    }
    final files = state.filesFor(album.id);
    final selecting = _selected.isNotEmpty;
    final scanning = state.isScanning(album.id);
    final uploadedCount = files.where((file) => state.isUploaded(file.path)).length;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: selecting
            ? IconButton(
                tooltip: '取消选择',
                onPressed: _clearSelection,
                icon: const Icon(Icons.close),
              )
            : null,
        title: Text(selecting ? '已选 ${_selected.length} 张' : album.name),
        actions: [
          if (selecting) ...[
            IconButton(
              tooltip: '全选',
              onPressed: _selected.length == files.length
                  ? _clearSelection
                  : () => setState(() {
                        _selected
                          ..clear()
                          ..addAll(files.map((file) => file.path));
                      }),
              icon: const Icon(Icons.select_all),
            ),
            IconButton(
              tooltip: '上传所选',
              onPressed: _starting ? null : () => _upload(state, album, files),
              icon: _starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
            ),
          ] else ...[
            IconButton(
              tooltip: '重新扫描',
              onPressed: scanning ? null : () => state.scanAlbum(album),
              icon: scanning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '上传全部',
              onPressed: files.isEmpty ? null : () => _upload(state, album, files),
              icon: const Icon(Icons.cloud_upload_outlined),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'select') {
                  setState(() => _selected.addAll(files.map((file) => file.path)));
                } else if (value == 'remove') {
                  _removeAlbum(state, album);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'select', child: Text('全选')),
                const PopupMenuItem(value: 'remove', child: Text('移除相册')),
              ],
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(
              children: [
                _InfoPill(
                  icon: Icons.image_outlined,
                  text: '${Fmt.count(files.length)} 张',
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                _InfoPill(
                  icon: Icons.cloud_done_outlined,
                  text: '已上传 ${Fmt.count(uploadedCount)}',
                  color: uploadedCount > 0 ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const Spacer(),
                Text(
                  state.networkLabel,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 6),
                Icon(
                  state.offline ? Icons.cloud_off : Icons.wifi,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (state.outcomeFor(album.id)?.truncated ?? false)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '照片太多，仅显示了前 ${Fmt.count(files.length)} 张',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
          Expanded(
            child: files.isEmpty
                ? (scanning
                    ? const Center(child: CircularProgressIndicator())
                    : EmptyState(
                        icon: Icons.no_photography_outlined,
                        title: '没有找到照片',
                        message: album.path,
                        action: FilledButton.icon(
                          onPressed: () => state.scanAlbum(album),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重新扫描'),
                        ),
                      ))
                : RefreshIndicator(
                    onRefresh: () => state.scanAlbum(album),
                    child: GridView.builder(
                      padding: const EdgeInsets.all(2),
                      physics: const AlwaysScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 2,
                        crossAxisSpacing: 2,
                      ),
                      itemCount: files.length,
                      itemBuilder: (context, index) {
                        final file = files[index];
                        final selected = _selected.contains(file.path);
                        final uploaded = state.isUploaded(file.path);
                        return _PhotoTile(
                          file: file,
                          selected: selected,
                          uploaded: uploaded,
                          selecting: selecting,
                          onTap: () {
                            if (selecting) {
                              _toggle(file.path);
                            } else {
                              _openViewer(files, index);
                            }
                          },
                          onLongPress: () => _toggle(file.path),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.file,
    required this.selected,
    required this.uploaded,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final MediaFile file;
  final bool selected;
  final bool uploaded;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Hero(
            tag: 'photo:${file.path}',
            child: Image.file(
              File(file.path),
              fit: BoxFit.cover,
              cacheWidth: 360,
              errorBuilder: (_, __, ___) => Container(
                color: scheme.surfaceContainerHighest,
                child: Icon(Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          if (uploaded)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cloud_done, size: 15, color: Colors.white),
              ),
            ),
          if (selected)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.28),
                  border: Border.all(color: scheme.primary, width: 3),
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.check_circle,
                        size: 20, color: scheme.primary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _StoragePicker extends StatelessWidget {
  const _StoragePicker({
    required this.storages,
    required this.count,
    required this.alreadyCount,
    required this.warnWifi,
    required this.uploadedCountOf,
  });

  final List<StorageConfig> storages;
  final int count;
  final int alreadyCount;
  final bool warnWifi;
  final int Function(String storageId) uploadedCountOf;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('上传 $count 张照片', style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              alreadyCount > 0
                  ? '其中 $alreadyCount 张已在目标存储上，会自动跳过'
                  : '照片会在后台上传，可随时暂停',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (warnWifi)
            Container(
              margin: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.wifi_off, size: 18, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '当前不在 Wi-Fi 下，任务会等待 Wi-Fi 后自动开始',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onTertiaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final storage in storages)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(storage.type.icon,
                          color: scheme.onPrimaryContainer),
                    ),
                    title: Text(storage.name),
                    subtitle: Text(
                      '${storage.type.label} · 已上传 ${uploadedCountOf(storage.id)} 张',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).pop(storage),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
