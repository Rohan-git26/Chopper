import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';

/// Wraps the opus_dart decoder for 16 kHz mono Opus → PCM16.
///
/// The chopper glasses send Opus frames at 16 kHz mono. After decoding we
/// get signed 16-bit little-endian PCM samples, which is exactly what the
/// ADK/Gemini Live path expects for `sendAudioChunk`.
class OpusAudioDecoder {
  late final SimpleOpusDecoder _decoder;
  bool _initialized = false;

  /// Sample rate the glasses encode at (must match server + decoder).
  static const int kSampleRate = 16000;

  static const int kChannels = 1;

  void init() {
    if (_initialized) return;
    _decoder = SimpleOpusDecoder(sampleRate: kSampleRate, channels: kChannels);
    _initialized = true;
  }

  /// Decodes a single Opus frame (variable length, typically ≤ 150 bytes)
  /// to 16-bit signed little-endian PCM.
  ///
  /// Returns a new [Uint8List] containing the PCM16 bytes. The caller owns
  /// the buffer and may pass it directly to `_service.sendAudioChunk`.
  Uint8List decode(Uint8List opusFrame) {
    if (!_initialized) {
      throw StateError('OpusAudioDecoder not initialised. Call init() first.');
    }
    if (opusFrame.isEmpty) return Uint8List(0);

    final Int16List pcmSamples = _decoder.decode(input: opusFrame);

    // Convert Int16List samples → Uint8List little-endian bytes.
    // Each sample is 2 bytes, little-endian (matches server & Android native).
    final bytes = Uint8List(pcmSamples.length * 2);
    final byteData = ByteData.view(bytes.buffer);
    for (int i = 0; i < pcmSamples.length; i++) {
      byteData.setInt16(i * 2, pcmSamples[i], Endian.little);
    }
    return bytes;
  }

  void dispose() {
    if (_initialized) {
      _decoder.destroy();
      _initialized = false;
    }
  }
}
