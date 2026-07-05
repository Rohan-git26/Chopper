import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';

/// Wraps microphone capture and PCM playback for live duplex voice.
///
/// - Input: 16 kHz mono signed-16-bit PCM streamed from the mic (what Gemini
///   Live / ADK expects for realtime audio input).
/// - Output: 24 kHz mono signed-16-bit PCM played through the speaker.
///
/// Playback is driven by `flutter_pcm_sound`'s feed callback (the pull model)
/// pulling from an internal jitter buffer. Crucially, when the buffer runs dry
/// we feed *silence* rather than nothing, so the underlying AudioTrack never
/// underruns and restarts — that underrun/restart is what produced the audible
/// clicks/crackle at the start of each reply. This mirrors the reference web
/// client's audio worklet, which outputs zeros when its queue is empty.
class AudioIo {
  final AudioRecorder _recorder = AudioRecorder();
  bool _playerReady = false;

  static const int _outputSampleRate = 24000;
  // Fire the feed callback once queued audio drops below ~100 ms...
  static const int _feedThreshold = 2400;
  // ...and top the AudioTrack up ~100 ms at a time.
  static const int _feedBlock = 2400;

  // Jitter buffer: decoded PCM chunks waiting to play, consumed by the feed
  // callback. Mirrors the web client's audioQueue + readIndex cursor.
  final Queue<Int16List> _queue = Queue<Int16List>();
  Int16List? _current;
  int _readIndex = 0;
  bool _started = false;

  Future<bool> hasMicPermission() => _recorder.hasPermission();

  /// Starts mic capture and returns the raw PCM16 byte stream.
  Future<Stream<Uint8List>> startMicStream() {
    return _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
  }

  Future<void> stopMic() async {
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
  }

  Future<void> initPlayer() async {
    if (_playerReady) return;
    // The plugin logs every feed()/OnFeedSamples at LogLevel.standard. Because
    // we feed continuously (incl. silence) that floods logcat ~10x/second and
    // wastes cycles; keep only real errors.
    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(sampleRate: _outputSampleRate, channelCount: 1);
    await FlutterPcmSound.setFeedThreshold(_feedThreshold);
    FlutterPcmSound.setFeedCallback(_onFeed);
    _playerReady = true;
  }

  /// Queues one chunk of 24 kHz PCM16 for playback. Bytes are little-endian,
  /// matching both Android's native order and the agent's output.
  void feed(Uint8List pcm16) {
    if (!_playerReady || pcm16.lengthInBytes < 2) return;
    // Own a copy: the socket's buffer may be reused, and this chunk lives in
    // our queue until the feed callback consumes it. asInt16List reads in host
    // order (little-endian on Android/x86), matching the server's PCM.
    final samples = Int16List.fromList(
      pcm16.buffer.asInt16List(pcm16.offsetInBytes, pcm16.lengthInBytes ~/ 2),
    );
    _queue.add(samples);
    if (!_started) {
      _started = true;
      // Kick off the feed-callback loop; it self-sustains from here.
      FlutterPcmSound.start();
    }
  }

  /// Drops all queued audio (barge-in). Whatever is already inside the
  /// AudioTrack (~100 ms) still plays out, then silence.
  void flush() {
    _queue.clear();
    _current = null;
    _readIndex = 0;
  }

  /// Pull callback: assemble exactly [_feedBlock] samples, drawing from the
  /// jitter buffer and padding the remainder with silence so the track stays
  /// alive between chunks.
  void _onFeed(int remainingFrames) {
    if (!_playerReady) return;
    final out = Int16List(_feedBlock);
    var i = 0;
    while (i < _feedBlock) {
      final chunk = _current;
      if (chunk == null || _readIndex >= chunk.length) {
        if (_queue.isEmpty) break; // pad the rest of `out` with silence
        _current = _queue.removeFirst();
        _readIndex = 0;
        continue;
      }
      out[i++] = chunk[_readIndex++];
    }
    // Any untouched tail of `out` stays zero (silence).
    FlutterPcmSound.feed(PcmArrayInt16.fromList(out));
  }

  Future<void> dispose() async {
    await stopMic();
    _playerReady = false;
    flush();
    _started = false;
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}
