import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import '../services/omi_device_service.dart' show kDefaultPhotoOrientationDegrees;

/// Live video viewer. The MJPEG stream is owned by [ChatProvider] (so the
/// capture path can snapshot the latest frame while streaming); this page just
/// drives Start/Stop and renders the frames. Requires WiFi to be connected.
class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  // Cache the provider so dispose() doesn't do a context lookup.
  late final ChatProvider _provider = Provider.of<ChatProvider>(context, listen: false);

  @override
  void dispose() {
    // Stop streaming when leaving the page — frees the device camera + WiFi
    // bandwidth. Deferred out of the dispose call stack so stopVideo()'s
    // synchronous notifier update doesn't rebuild this subtree mid-teardown.
    final provider = _provider;
    Future.microtask(provider.stopVideo);
    super.dispose();
  }

  void _start() {
    if (_provider.wifiIp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect the glasses to WiFi first')),
      );
      return;
    }
    _provider.startVideo();
  }

  void _stop() => _provider.stopVideo();

  @override
  Widget build(BuildContext context) {
    final ip = context.select<ChatProvider, String?>((p) => p.wifiIp);
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF15151B),
        elevation: 0,
        title: const Text('Live Video'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: double.infinity,
                  color: Colors.black,
                  child: ValueListenableBuilder<String?>(
                    valueListenable: _provider.videoError,
                    builder: (context, error, _) {
                      if (error != null) {
                        return _centerMessage(
                          Icons.error_outline,
                          'Stream error\n$error',
                          Colors.redAccent,
                        );
                      }
                      return ValueListenableBuilder<Uint8List?>(
                        valueListenable: _provider.videoFrame,
                        builder: (context, frame, _) {
                          if (frame == null) {
                            return _centerMessage(
                              Icons.videocam_off,
                              ip == null ? 'WiFi not connected' : 'Press Start to begin',
                              Colors.white38,
                            );
                          }
                          // MJPEG frames arrive in the raw sensor orientation
                          // (no metadata); rotate for display to match the
                          // device's fixed orientation used by the capture path.
                          // Display-only — no re-encode, so it's cheap.
                          return RotatedBox(
                            quarterTurns: kDefaultPhotoOrientationDegrees ~/ 90,
                            child: Image.memory(
                              frame,
                              gaplessPlayback: true,
                              fit: BoxFit.contain,
                              width: double.infinity,
                              height: double.infinity,
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              ip == null ? 'Device WiFi: not connected' : 'Device: $ip:81',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: _provider.videoRunning,
              builder: (context, running, _) {
                return SizedBox(
                  width: double.infinity,
                  child: running
                      ? OutlinedButton.icon(
                          onPressed: _stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        )
                      : ElevatedButton.icon(
                          onPressed: _start,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start'),
                        ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _centerMessage(IconData icon, String text, Color color) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 42),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: color, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

