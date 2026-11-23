import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_log.dart';
import '../../core/crash_log.dart';
import '../widgets/dialogs.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String _crashText = '';
  bool _loadingCrash = true;

  @override
  void initState() {
    super.initState();
    _loadCrash();
  }

  Future<void> _loadCrash() async {
    final text = await CrashLog.read();
    if (!mounted) return;
    setState(() {
      _crashText = text;
      _loadingCrash = false;
    });
  }

  Color _color(LogLevel level, ColorScheme scheme) => switch (level) {
        LogLevel.debug => scheme.outline,
        LogLevel.info => scheme.onSurface,
        LogLevel.warn => const Color(0xFFEF6C00),
        LogLevel.error => scheme.error,
      };

  Future<void> _showCrash() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('崩溃记录'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              _crashText,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _crashText));
              navigator.pop();
              messenger.showSnackBar(
                const SnackBar(content: Text('崩溃记录已复制，可粘贴发送给开发者')),
              );
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () async {
              final dir = await getExternalStorageDirectory();
              final path = await CrashLog.exportToVisibleDir(dir);
              navigator.pop();
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    path == null ? '导出失败，可以改用「复制」' : '已导出到：$path',
                  ),
                ),
              );
            },
            child: const Text('导出到手机存储'),
          ),
          TextButton(
            onPressed: () => navigator.pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearCrash() async {
    final ok = await confirmAction(
      context,
      title: '清除崩溃记录',
      message: '删除已保存的崩溃日志文件。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok) return;
    await CrashLog.clear();
    await _loadCrash();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: AppLog.instance,
      builder: (context, _) {
        final entries = AppLog.instance.entries;
        final hasCrash = _crashText.isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: const Text('运行日志'),
            actions: [
              if (hasCrash)
                IconButton(
                  tooltip: '崩溃记录',
                  onPressed: _showCrash,
                  icon: Icon(Icons.bug_report_outlined, color: scheme.error),
                ),
              IconButton(
                tooltip: '复制全部',
                onPressed: entries.isEmpty
                    ? null
                    : () async {
                        final text = hasCrash
                            ? '${AppLog.instance.dump()}\n\n$_crashText'
                            : AppLog.instance.dump();
                        await Clipboard.setData(ClipboardData(text: text));
                        if (context.mounted) showMessage(context, '日志已复制');
                      },
                icon: const Icon(Icons.copy_all_outlined),
              ),
              IconButton(
                tooltip: '清空',
                onPressed: entries.isEmpty && !hasCrash
                    ? null
                    : () async {
                        final ok = await confirmAction(
                          context,
                          title: '清空日志',
                          message: '将清空当前会话的全部日志'
                              '${hasCrash ? '，以及已保存的崩溃记录' : ''}。',
                          confirmLabel: '清空',
                          destructive: true,
                        );
                        if (!ok) return;
                        AppLog.instance.clear();
                        if (hasCrash) await _clearCrash();
                      },
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
          ),
          body: Column(
            children: [
              if (hasCrash)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Material(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: _showCrash,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(Icons.bug_report_outlined,
                                color: scheme.onErrorContainer),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '检测到上次运行异常，点此查看崩溃记录（可复制发送）',
                                style: TextStyle(
                                  color: scheme.onErrorContainer,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Icon(Icons.chevron_right,
                                color: scheme.onErrorContainer),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_loadingCrash && entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无日志',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.formatted.substring(0, 8),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 58,
                                  child: Text(
                                    entry.tag,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: SelectableText(
                                    entry.message,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _color(entry.level, scheme),
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
