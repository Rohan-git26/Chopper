import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import 'auth_service.dart';

/// Events emitted by the ADK bidi-streaming server, normalized from the wire
/// protocol into typed values the [ChatProvider] can pattern-match on.
sealed class AdkEvent {
  const AdkEvent();
}

/// A streamed chunk of the assistant's text, decoded from the server's
/// `output_transcription` (the model's spoken reply, transcribed to text).
/// Chunks are incremental deltas and should be concatenated.
class AdkTextDelta extends AdkEvent {
  final String text;
  final bool isFinal;
  const AdkTextDelta(this.text, {this.isFinal = false});
}

/// A streamed chunk of the user's own speech-to-text, decoded from the server's
/// `input_transcription`. Chunks are incremental deltas.
class AdkUserTranscript extends AdkEvent {
  final String text;
  final bool isFinal;
  const AdkUserTranscript(this.text, {this.isFinal = false});
}

/// A chunk of assistant audio output - 24 kHz signed 16-bit little-endian PCM.
class AdkAudioChunk extends AdkEvent {
  final Uint8List pcm;
  const AdkAudioChunk(this.pcm);
}

/// The current model turn finished (`{"turn_complete":true}`).
class AdkTurnComplete extends AdkEvent {
  const AdkTurnComplete();
}

/// The user barged in and the model output was cut off (`{"interrupted":true}`).
class AdkInterrupted extends AdkEvent {
  const AdkInterrupted();
}

/// Server requested a photo from the connected glasses (via `capture_image` tool).
class AdkCaptureImage extends AdkEvent {
  const AdkCaptureImage();
}

/// Transport-level connection state changes.
class AdkConnectionChanged extends AdkEvent {
  final bool connected;
  final String? error;
  const AdkConnectionChanged(this.connected, {this.error});
}

/// Owns the WebSocket to the Chopper ADK bidi-streaming agent and speaks the
/// server's protocol (see `server/main.py`).
///
/// Outbound (client -> server):
/// ```
/// <binary frame>                                     // raw 16kHz PCM16 mic audio
/// {"mime_type": "text/plain", "data": "<utf8 text>"}      // typed text
/// {"mime_type": "image/jpeg", "data": "<base64 bytes>"}   // image blobs
/// ```
///
/// Inbound (server -> client), one JSON object per frame:
/// ```
/// {
///   "author": "agent",
///   "turn_complete": <bool>,
///   "interrupted": <bool>,
///   "parts": [ {"type": "audio/pcm", "data": "<base64 24kHz PCM16>"} ],
///   "input_transcription":  {"text": "...", "is_final": <bool>} | null,
///   "output_transcription": {"text": "...", "is_final": <bool>} | null
/// }
/// ```
class AuthenticatedWebSocketConnection {
  AuthenticatedWebSocketConnection._(this._socket);

  final io.WebSocket _socket;
  late final Future<void> ready = Future.value();

  Stream<dynamic> get stream => _socket.map((event) => event);
  _AuthenticatedSocketSink get sink => _sink;
  late final _AuthenticatedSocketSink _sink;   // ← changed from `final` to `late final`

  static Future<AuthenticatedWebSocketConnection> connect(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    final socket = await io.WebSocket.connect(uri.toString(), headers: headers);
    final connection = AuthenticatedWebSocketConnection._(socket);
    connection._sink = _AuthenticatedSocketSink(socket);
    return connection;
  }
}

class _AuthenticatedSocketSink implements StreamSink<dynamic> {
  _AuthenticatedSocketSink(this._socket);

  final io.WebSocket _socket;

  @override
  void add(dynamic data) {
    if (data is Uint8List) {
      _socket.add(data);
    } else if (data is List<int>) {
      _socket.add(data);
    } else {
      _socket.add(data.toString());
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    throw error;
  }

  @override
  Future addStream(Stream<dynamic> stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;
}

class AdkAgentService {
  AuthenticatedWebSocketConnection? _channel;
  StreamSubscription? _sub;
  bool _isAudio = false;

  final _events = StreamController<AdkEvent>.broadcast();

  Stream<AdkEvent> get events => _events.stream;
  bool get isConnected => _channel != null;
  bool get isAudioMode => _isAudio;

  /// (Re)connects. The response modality (text vs audio) is fixed for the life
  /// of a Gemini Live session, so switching between typed chat and live voice
  /// requires reconnecting with a different [isAudio] value.
  Future<void> connect({required bool isAudio}) async {
    await _teardown();
    _isAudio = isAudio;

    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    final channel = await AuthenticatedWebSocketConnection.connect(
      AppConfig.wsUri(isAudio: isAudio),
      headers: token == null ? null : {'Authorization': 'Bearer $token'},
    );
    _channel = channel;
    try {
      await channel.ready;
    } catch (e) {
      _channel = null;
      _events.add(AdkConnectionChanged(false, error: e.toString()));
      rethrow;
    }

    _sub = channel.stream.listen(
      _onData,
      onError: (Object e) => _events.add(AdkConnectionChanged(false, error: e.toString())),
      onDone: () {
        _channel = null;
        _events.add(const AdkConnectionChanged(false));
      },
    );
    _events.add(const AdkConnectionChanged(true));

    // Send Google OAuth Access Token to backend for Calendar/Tasks APIs
    try {
      final googleAccessToken = await AuthService.instance.getGoogleAccessToken();
      if (googleAccessToken != null) {
        _send({
          'mime_type': 'application/x-google-auth',
          'data': googleAccessToken,
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print("Failed to send Google Access Token to backend: $e");
      }
    }
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return;
    }

    // User speech-to-text (what the user said).
    final inputTx = msg['input_transcription'];
    if (inputTx is Map && inputTx['text'] is String) {
      _events.add(AdkUserTranscript(
        inputTx['text'] as String,
        isFinal: inputTx['is_final'] == true,
      ));
    }

    // Assistant text (the model's spoken reply, transcribed).
    final outputTx = msg['output_transcription'];
    if (outputTx is Map && outputTx['text'] is String) {
      _events.add(AdkTextDelta(
        outputTx['text'] as String,
        isFinal: outputTx['is_final'] == true,
      ));
    }

    // Audio output is carried inside `parts`, base64-encoded 24kHz PCM16.
    final parts = msg['parts'];
    if (parts is List) {
      for (final part in parts) {
        if (part is Map &&
            part['type'] is String &&
            (part['type'] as String).startsWith('audio/') &&
            part['data'] is String) {
          _events.add(AdkAudioChunk(base64Decode(part['data'] as String)));
        }
      }
    }

    // End-of-turn / barge-in markers (top-level booleans).
    if (msg['turn_complete'] == true) _events.add(const AdkTurnComplete());
    if (msg['interrupted'] == true) _events.add(const AdkInterrupted());

    // Server-side tool triggers (Phase 3: capture_image).
    if (msg['type'] == 'capture_image') {
      _events.add(const AdkCaptureImage());
    }
  }

  void sendText(String text) => _send({'mime_type': 'text/plain', 'data': text});

  /// Sends mic audio as a raw binary frame. The server reads binary frames as
  /// 16kHz PCM16 audio (`raw.get("bytes")`); a base64 JSON text frame would be
  /// rejected as an unsupported mime type.
  void sendAudioChunk(Uint8List pcm) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(pcm);
  }

  void sendBlob(Uint8List bytes, String mimeType) =>
      _send({'mime_type': mimeType, 'data': base64Encode(bytes)});

  void _send(Map<String, dynamic> frame) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(frame));
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> dispose() async {
    await _teardown();
    await _events.close();
  }
}

