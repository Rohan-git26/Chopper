import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// No-op [TaskHandler]. The main isolate owns BLE, WebSocket, opus decode,
/// and PCM playback. The foreground service exists solely to keep the process
/// alive while the device remains connected in the background.
@pragma('vm:entry-point')
class ForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // The main isolate already runs the real audio and transport pipeline.
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // No periodic work is required.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Nothing to clean up here.
  }
}
