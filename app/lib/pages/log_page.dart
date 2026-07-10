import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_log.dart';

/// On-screen log viewer. Shows lines added via [AppLog], newest at the bottom.
/// Useful for debugging on a device where adb / `flutter attach` isn't possible.
class LogPage extends StatelessWidget {
  const LogPage({super.key});

  String _ts(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF15151B),
        elevation: 0,
        title: const Text('Logs'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all),
            onPressed: () {
              final text = AppLog.instance.entries.value
                  .map((e) => '${_ts(e.time)}  ${e.message}')
                  .join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied to clipboard')),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => AppLog.instance.clear(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<LogEntry>>(
        valueListenable: AppLog.instance.entries,
        builder: (context, entries, _) {
          if (entries.isEmpty) {
            return const Center(
              child: Text('No logs yet',
                  style: TextStyle(color: Colors.grey, fontSize: 14)),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            reverse: true, // newest at the bottom, auto-stick to latest
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[entries.length - 1 - i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: SelectableText(
                  '${_ts(e.time)}  ${e.message}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.3,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
