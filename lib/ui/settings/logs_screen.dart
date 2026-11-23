import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_log.dart';
import '../widgets/dialogs.dart';

class LogsScreen extends StatelessWidget {
  const LogsScreen({super.key});

  Color _color(LogLevel level, ColorScheme scheme) => switch (level) {
        LogLevel.debug => scheme.outline,
        LogLevel.info => scheme.onSurface,
        LogLevel.warn => const Color(0xFFEF6C00),
        LogLevel.error => scheme.error,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: AppLog.instance,
      builder: (context, _) {
        final entries = AppLog.instance.entries;
        return Scaffold(
          appBar: AppBar(
            title: const Text('运行日志'),
            actions: [
              IconButton(
                tooltip: '复制全部',
                onPressed: entries.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(
                          ClipboardData(text: AppLog.instance.dump()),
                        );
                        if (context.mounted) showMessage(context, '日志已复制');
                      },
                icon: const Icon(Icons.copy_all_outlined),
              ),
              IconButton(
                tooltip: '清空',
                onPressed: entries.isEmpty
                    ? null
                    : () async {
                        final ok = await confirmAction(
                          context,
                          title: '清空日志',
                          message: '将清空当前会话的全部日志。',
                          confirmLabel: '清空',
                          destructive: true,
                        );
                        if (ok) AppLog.instance.clear();
                      },
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
          ),
          body: entries.isEmpty
              ? const Center(
                  child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
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
        );
      },
    );
  }
}
