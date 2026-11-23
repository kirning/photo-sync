import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../core/permissions.dart';
import '../../models/album.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';
import 'album_detail_screen.dart';

class AlbumsScreen extends StatelessWidget {
  const AlbumsScreen({super.key});

  Future<void> _addDirectory(BuildContext context, AppState state) async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择照片目录',
      );
      if (selected == null || selected.isEmpty) return;
      if (!context.mounted) return;
      final album = await state.addManualAlbum(selected);
      if (!context.mounted) return;
      if (album != null) {
        showMessage(context, '已添加相册「${album.name}」');
      }
    } on FileSystemException {
      // 部分机型的选择器只返回 content:// URI，无法直接按路径读取，
      // 这时引导用户手动填写实际目录。
      if (context.mounted) await _promptManualPath(context, state);
    } catch (error) {
      if (context.mounted) {
        showMessage(context, '添加目录失败：$error，可以手动输入路径', error: true);
        await _promptManualPath(context, state);
      }
    }
  }

  /// 手动输入目录路径：FilePicker 在个别系统上拿不到真实路径时使用。
  Future<void> _promptManualPath(BuildContext context, AppState state) async {
    final controller = TextEditingController(
      text: '/storage/emulated/0/Pictures',
    );
    final path = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('手动输入目录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('输入照片所在目录的完整路径：'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '目录路径',
                hintText: '/storage/emulated/0/DCIM/Camera',
              ),
              onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
            ),
            const SizedBox(height: 12),
            Text(
              '常见路径：/storage/emulated/0/DCIM/Camera、'
              '/storage/emulated/0/Pictures、/storage/emulated/0/Download',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    try {
      final album = await state.addManualAlbum(path);
      if (album == null) return;
      if (context.mounted) {
        showMessage(context, '已添加相册「${album.name}」');
      }
    } catch (error) {
      if (context.mounted) {
        showMessage(context, '无法读取该目录：$error', error: true);
      }
    }
  }

  Future<void> _importBuiltin(BuildContext context, AppState state) async {
    final added = await state.importBuiltinAlbums();
    if (!context.mounted) return;
    showMessage(
      context,
      added > 0 ? '已添加 $added 个系统相册目录' : '没有发现新的系统相册目录',
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final albums = state.albums;
    return Scaffold(
      appBar: AppBar(
        title: const Text('相册'),
        actions: [
          IconButton(
            tooltip: '导入系统相册目录',
            onPressed: () => _importBuiltin(context, state),
            icon: const Icon(Icons.auto_awesome_mosaic_outlined),
          ),
          IconButton(
            tooltip: '扫描全部',
            onPressed: albums.isEmpty ? null : () => state.scanAll(),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'path') _promptManualPath(context, state);
            },
            itemBuilder: (menuContext) => const [
              PopupMenuItem(
                value: 'path',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.keyboard_outlined),
                  title: Text('手动输入目录路径'),
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addDirectory(context, state),
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('添加目录'),
      ),
      body: Column(
        children: [
          if (state.mediaAccess != MediaAccess.granted)
            _PermissionBanner(onOpenSettings: openSystemSettings),
          Expanded(
            child: albums.isEmpty
                ? EmptyState(
                    icon: Icons.photo_library_outlined,
                    title: '还没有相册',
                    message: '应用会自动发现相机、截图、下载等常见目录，\n也可以手动添加任意照片目录。',
                    action: FilledButton.icon(
                      onPressed: () => _importBuiltin(context, state),
                      icon: const Icon(Icons.search),
                      label: const Text('扫描系统目录'),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: albums.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final album = albums[index];
                      return _AlbumCard(
                        album: album,
                        state: state,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => AlbumDetailScreen(albumId: album.id),
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

class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({required this.onOpenSettings});

  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '没有读取照片的权限，无法扫描相册',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(
            onPressed: onOpenSettings,
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({
    required this.album,
    required this.state,
    required this.onTap,
  });

  final Album album;
  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scanning = state.isScanning(album.id);
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Cover(path: album.coverPath),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            album.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (album.source == AlbumSource.builtin)
                          _Tag(label: '系统', color: scheme.secondary),
                        if (!album.enabled)
                          _Tag(label: '已停用', color: scheme.outline),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      album.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.image_outlined,
                            size: 14, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          '${Fmt.count(album.photoCount)} 张',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        if (album.uploadedCount > 0) ...[
                          const SizedBox(width: 12),
                          Icon(Icons.cloud_done_outlined,
                              size: 14, color: scheme.primary),
                          const SizedBox(width: 4),
                          Text(
                            '已上传 ${Fmt.count(album.uploadedCount)}',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(color: scheme.primary),
                          ),
                        ],
                        if (scanning) ...[
                          const SizedBox(width: 10),
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ] else if (album.lastScanAt != null) ...[
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              Fmt.relative(album.lastScanAt!),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) async {
                  switch (value) {
                    case 'scan':
                      await state.scanAlbum(album);
                    case 'enable':
                      await state.setAlbumEnabled(album, !album.enabled);
                    case 'remove':
                      final ok = await confirmAction(
                        context,
                        title: '移除相册',
                        message: '仅从应用中移除「${album.name}」，不会删除手机上的照片。',
                        confirmLabel: '移除',
                        destructive: true,
                      );
                      if (ok) await state.removeAlbum(album);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'scan', child: Text('重新扫描')),
                  PopupMenuItem(
                    value: 'enable',
                    child: Text(album.enabled ? '停用相册' : '启用相册'),
                  ),
                  const PopupMenuItem(value: 'remove', child: Text('移除相册')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = path == null ? null : File(path!);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 68,
        height: 68,
        child: file == null
            ? _placeholder(scheme)
            : Image.file(
                file,
                fit: BoxFit.cover,
                cacheWidth: 240,
                errorBuilder: (_, __, ___) => _placeholder(scheme),
              ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.photo_outlined, color: scheme.onSurfaceVariant),
      );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontSize: 10),
      ),
    );
  }
}
