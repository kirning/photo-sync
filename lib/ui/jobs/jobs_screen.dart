import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../models/upload_job.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';
import 'job_detail_screen.dart';

class JobsScreen extends StatelessWidget {
  const JobsScreen({super.key, this.onOpenAlbums});

  final VoidCallback? onOpenAlbums;

  Future<void> _clearFinished(BuildContext context, AppState state) async {
    final finished = state.jobs.where((job) => job.state.isFinished).length;
    if (finished == 0) {
      showMessage(context, '没有已完成的任务');
      return;
    }
    final ok = await confirmAction(
      context,
      title: '清理已完成任务',
      message: '将删除 $finished 条已完成/已取消的任务记录，'
          '已上传照片的标记会保留。',
      confirmLabel: '清理',
    );
    if (!ok || !context.mounted) return;
    await state.clearFinishedJobs();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final jobs = [
      ...state.jobs.where((job) => !job.state.isFinished),
      ...state.jobs.where((job) => job.state.isFinished),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('上传任务'),
        actions: [
          IconButton(
            tooltip: '清理已完成任务',
            onPressed: () => _clearFinished(context, state),
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: jobs.isEmpty
          ? EmptyState(
              icon: Icons.sync_outlined,
              title: '还没有上传任务',
              message: '在相册里选择照片上传后，任务会显示在这里，\n上传在后台进行，退出应用也不会中断。',
              action: onOpenAlbums == null
                  ? null
                  : FilledButton.icon(
                      onPressed: onOpenAlbums,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('去相册选择照片'),
                    ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: jobs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _JobCard(
                job: jobs[index],
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => JobDetailScreen(jobId: jobs[index].id),
                  ),
                ),
              ),
            ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job, required this.onTap});

  final UploadJob job;
  final VoidCallback onTap;

  Future<void> _onAction(BuildContext context, AppState state, String action) async {
    switch (action) {
      case 'pause':
        await state.pauseJob(job);
      case 'resume':
        await state.resumeJob(job);
      case 'cancel':
        final ok = await confirmAction(
          context,
          title: '取消任务',
          message: '取消后已上传的文件会保留标记，剩余文件不再上传。',
          confirmLabel: '取消任务',
          destructive: true,
        );
        if (ok) await state.cancelJob(job);
      case 'delete':
        final ok = await confirmAction(
          context,
          title: '删除任务记录',
          message: '只删除任务记录，不会删除已上传的云端照片。',
          confirmLabel: '删除',
          destructive: true,
        );
        if (ok) await state.removeJob(job);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.read<AppState>();
    final color = job.state.color(scheme);
    final active = job.state == JobState.running || job.state == JobState.paused;
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(job.state.icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            job.albumLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          job.state.label,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: color),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '→ ${job.storageName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    if (active || job.state == JobState.queued)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: job.state == JobState.queued ? null : job.progress,
                          minHeight: 6,
                        ),
                      ),
                    if (active || job.state == JobState.queued) ...[
                      const SizedBox(height: 6),
                      Text(
                        job.state == JobState.queued
                            ? '等待开始…'
                            : '${job.processed}/${job.totalItems} · '
                                '${Fmt.percent(job.progress)}'
                                '${job.state == JobState.running ? ' · ${Fmt.bytes(job.doneBytes)}' : ''}',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      if (job.state == JobState.running && job.currentName != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          job.currentName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ] else ...[
                      const SizedBox(height: 6),
                      Text(
                        '成功 ${job.doneCount}'
                        '${job.skippedCount > 0 ? ' · 跳过 ${job.skippedCount}' : ''}'
                        '${job.failedCount > 0 ? ' · 失败 ${job.failedCount}' : ''}'
                        ' · ${Fmt.bytes(job.doneBytes)}',
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      if (job.message != null && job.message!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          job.message!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: color),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) => _onAction(context, state, value),
                itemBuilder: (context) => [
                  if (job.state == JobState.running)
                    const PopupMenuItem(value: 'pause', child: Text('暂停')),
                  if (job.state == JobState.paused)
                    const PopupMenuItem(value: 'resume', child: Text('继续')),
                  if (job.state.isActive || job.state == JobState.queued)
                    const PopupMenuItem(value: 'cancel', child: Text('取消任务')),
                  const PopupMenuItem(value: 'delete', child: Text('删除记录')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
