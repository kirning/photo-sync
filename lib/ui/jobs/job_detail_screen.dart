import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/formatters.dart';
import '../../models/upload_job.dart';
import '../../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/empty_state.dart';

enum _ResultFilter { all, uploaded, skipped, failed }

class JobDetailScreen extends StatefulWidget {
  const JobDetailScreen({super.key, required this.jobId});

  final String jobId;

  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  Timer? _timer;
  _ResultFilter _filter = _ResultFilter.all;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      final job = context.read<AppState>().jobById(widget.jobId);
      if (job == null || job.state.isFinished) {
        _timer?.cancel();
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _onAction(AppState state, UploadJob job, String action) async {
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
        if (ok && mounted) {
          await state.removeJob(job);
          if (mounted) Navigator.of(context).pop();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final job = state.jobById(widget.jobId);
    if (job == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('任务详情')),
        body: const EmptyState(icon: Icons.cloud_off_outlined, title: '任务已删除'),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final color = job.state.color(scheme);
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务详情'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) => _onAction(state, job, value),
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
      body: FutureBuilder<List<JobResult>>(
        future: state.repo.readResults(job.id),
        builder: (context, snapshot) {
          final results = snapshot.data ?? const <JobResult>[];
          final filtered = switch (_filter) {
            _ResultFilter.all => results,
            _ResultFilter.uploaded =>
              results.where((e) => e.status == 'uploaded').toList(),
            _ResultFilter.skipped =>
              results.where((e) => e.status == 'skipped').toList(),
            _ResultFilter.failed =>
              results.where((e) => e.status == 'failed').toList(),
          };
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(job.state.icon, color: color),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(job.albumLabel,
                                style: Theme.of(context).textTheme.titleMedium),
                          ),
                          Text(job.state.label,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(color: color)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: job.state == JobState.queued ? null : job.progress,
                          minHeight: 8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${job.processed}/${job.totalItems} · ${Fmt.percent(job.progress)}'
                        ' · ${Fmt.bytes(job.doneBytes)}',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      if (job.currentName != null &&
                          job.currentName!.isNotEmpty &&
                          job.state == JobState.running) ...[
                        const SizedBox(height: 4),
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
                      if (job.message != null && job.message!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          job.message!,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: color),
                        ),
                      ],
                      const Divider(height: 24),
                      _KeyValue(label: '存储', value: job.storageName),
                      _KeyValue(
                        label: '网络',
                        value: job.wifiOnly ? '仅 Wi-Fi' : 'Wi-Fi 与移动数据',
                      ),
                      _KeyValue(
                        label: '总量',
                        value: '${job.totalItems} 张 · ${Fmt.bytes(job.totalBytes)}',
                      ),
                      _KeyValue(label: '已上传', value: '${job.doneCount} 张'),
                      if (job.skippedCount > 0)
                        _KeyValue(label: '已跳过', value: '${job.skippedCount} 张'),
                      if (job.failedCount > 0)
                        _KeyValue(
                          label: '失败',
                          value: '${job.failedCount} 张',
                          valueColor: scheme.error,
                        ),
                      _KeyValue(
                        label: '创建时间',
                        value: Fmt.dateTime(job.createdAt),
                      ),
                      if (job.startedAt != null)
                        _KeyValue(
                          label: '开始时间',
                          value: Fmt.dateTime(job.startedAt!),
                        ),
                      if (job.finishedAt != null)
                        _KeyValue(
                          label: '结束时间',
                          value: Fmt.dateTime(job.finishedAt!),
                        ),
                      if (job.state.isActive || job.state == JobState.queued)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              if (job.state == JobState.running)
                                OutlinedButton.icon(
                                  onPressed: () => state.pauseJob(job),
                                  icon: const Icon(Icons.pause),
                                  label: const Text('暂停'),
                                ),
                              if (job.state == JobState.paused)
                                FilledButton.icon(
                                  onPressed: () => state.resumeJob(job),
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('继续'),
                                ),
                              const SizedBox(width: 10),
                              TextButton.icon(
                                onPressed: () => _onAction(state, job, 'cancel'),
                                icon: const Icon(Icons.stop_circle_outlined),
                                label: const Text('取消'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 8),
                    child: Text('文件明细',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  Text(
                    '共 ${results.length} 条',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in const {
                    _ResultFilter.all: '全部',
                    _ResultFilter.uploaded: '已上传',
                    _ResultFilter.skipped: '已跳过',
                    _ResultFilter.failed: '失败',
                  }.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: _filter == entry.key,
                      onSelected: (_) => setState(() => _filter = entry.key),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('暂无记录', style: TextStyle(color: Colors.grey)),
                  ),
                )
              else
                for (final result in filtered)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        switch (result.status) {
                          'uploaded' => Icons.cloud_done_outlined,
                          'skipped' => Icons.skip_next_outlined,
                          _ => Icons.error_outline,
                        },
                        color: switch (result.status) {
                          'uploaded' => const Color(0xFF2E7D32),
                          'skipped' => scheme.onSurfaceVariant,
                          _ => scheme.error,
                        },
                      ),
                      title: Text(
                        result.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        result.status == 'failed'
                            ? (result.error ?? '上传失败')
                            : (result.remotePath ?? ''),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
