import 'package:flutter/foundation.dart';

/// A single on-screen log line with a timestamp.
class LogEntry {
  final DateTime time;
  final String message;
  const LogEntry(this.time, this.message);
}

/// A tiny in-app logger for on-device debugging when adb / `flutter attach`
/// aren't available (e.g. USB blocked, wireless debugging disabled).
///
/// Only *explicit* [add] calls land here — high-frequency events (audio frames,
/// per-chunk photo notifications) are intentionally NOT logged, to keep the
/// on-screen log readable. View it via [LogPage].
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  /// Keep only the most recent N lines so the buffer can't grow unbounded.
  static const int _maxEntries = 300;

  final ValueNotifier<List<LogEntry>> entries =
      ValueNotifier<List<LogEntry>>(<LogEntry>[]);

  void add(String message) {
    // Mirror to the debug console too (harmless when nothing is attached).
    debugPrint('[AppLog] $message');
    final next = [...entries.value, LogEntry(DateTime.now(), message)];
    if (next.length > _maxEntries) {
      next.removeRange(0, next.length - _maxEntries);
    }
    entries.value = next;
  }

  void clear() => entries.value = <LogEntry>[];
}

/// Convenience shorthand for `AppLog.instance.add(...)`.
void logUi(String message) => AppLog.instance.add(message);
