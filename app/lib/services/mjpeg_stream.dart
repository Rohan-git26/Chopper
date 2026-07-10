import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_log.dart';
import 'http_util.dart';

/// Reads an MJPEG (`multipart/x-mixed-replace`) HTTP stream and extracts the
/// individual JPEG frames by scanning for the JPEG start-of-image (FF D8) and
/// end-of-image (FF D9) markers — robust to how the server formats its
/// multipart boundaries.
///
/// Each decoded frame is published to [frame] (for on-screen display via
/// `Image.memory`) and passed to the optional [onFrame] callback, which the
/// recording feature (Phase 2) hooks into so a single connection drives both
/// the viewer and the recorder.
class MjpegStream {
  MjpegStream({this.onFrame});

  /// Invoked for every complete JPEG frame received.
  final void Function(Uint8List frame)? onFrame;

  /// Latest frame, for the viewer to render.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  /// Last error message (null when healthy).
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  /// Whether the stream is currently connected/running.
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;
  final List<int> _buf = <int>[];
  bool _active = false;

  static const int _maxBuffer = 1 << 20; // 1 MB safety cap

  /// Open [url] (e.g. `http://<ip>:81/stream`) and begin decoding frames.
  Future<void> start(String url) async {
    if (_active) return;
    _active = true;
    running.value = true;
    error.value = null;
    _buf.clear();
    try {
      _client = HttpClient();
      final response = await httpGetOk(_client!, url);
      AppLog.instance.add('🎥 stream connected: $url');
      _sub = response.listen(
        _onData,
        onError: (Object e) => _fail('$e'),
        onDone: () {
          AppLog.instance.add('🎥 stream ended');
          stop();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _fail('$e');
    }
  }

  void _onData(List<int> chunk) {
    // A buffered chunk can arrive after stop()/dispose() (stream cancellation is
    // async). _active is cleared synchronously in stop(), so bail before touching
    // the (possibly disposed) notifiers.
    if (!_active) return;
    _buf.addAll(chunk);
    while (true) {
      final soi = _find(_buf, 0xFF, 0xD8, 0);
      if (soi < 0) {
        if (_buf.length > _maxBuffer) _buf.clear();
        break;
      }
      final eoi = _find(_buf, 0xFF, 0xD9, soi + 2);
      if (eoi < 0) {
        // Incomplete frame — drop anything before the start marker to bound memory.
        if (soi > 0) _buf.removeRange(0, soi);
        if (_buf.length > _maxBuffer) _buf.clear();
        break;
      }
      final jpeg = Uint8List.fromList(_buf.sublist(soi, eoi + 2));
      _buf.removeRange(0, eoi + 2);
      frame.value = jpeg;
      onFrame?.call(jpeg);
    }
  }

  /// Find the first occurrence of the byte pair [a],[b] at/after [from].
  int _find(List<int> b, int a, int c, int from) {
    for (int i = from; i < b.length - 1; i++) {
      if (b[i] == a && b[i + 1] == c) return i;
    }
    return -1;
  }

  void _fail(String message) {
    AppLog.instance.add('🎥 stream error: $message');
    error.value = message;
    stop();
  }

  /// Stop the stream and release the connection.
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    running.value = false;
    await _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    _buf.clear();
  }

  void dispose() {
    stop();
    frame.dispose();
    error.dispose();
    running.dispose();
  }
}
