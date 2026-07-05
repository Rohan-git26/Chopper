import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../models/chat_message.dart';
import '../services/adk_agent_service.dart';
import '../services/audio_io.dart';
import '../services/omi_device_service.dart';
import '../services/opus_audio_decoder.dart';

enum AgentConnection { connecting, connected, disconnected }

/// Orchestrates the chat: owns the message list + composer state, drives the
/// [AdkAgentService] and [AudioIo], and folds streamed agent events back into
/// the UI. The [ChatPage] is a thin `Consumer` on top of this.
class ChatProvider extends ChangeNotifier {
  final AdkAgentService _service;
  final AudioIo _audio;

  ChatProvider({AdkAgentService? service, AudioIo? audio})
      : _service = service ?? AdkAgentService(),
        _audio = audio ?? AudioIo() {
    _init();
  }

  final List<ChatMessage> messages = [];
  final List<Attachment> staged = [];

  bool sendingMessage = false;
  bool voiceActive = false;
  AgentConnection connection = AgentConnection.connecting;
  String? connectionError;

  // ---- Device audio (chopper glasses) --------------------------------------

  final OmiDeviceService _device = OmiDeviceService();
  final OpusAudioDecoder _opusDecoder = OpusAudioDecoder();

  DeviceConnectionState get deviceState => _device.currentState;
  bool get deviceConnected => _device.currentState == DeviceConnectionState.connected;
  String get deviceStatusText {
    switch (_device.currentState) {
      case DeviceConnectionState.scanning:  return 'Scanning…';
      case DeviceConnectionState.connecting: return 'Connecting…';
      case DeviceConnectionState.connected:  return 'Connected';
      case DeviceConnectionState.error:      return 'Error';
      case DeviceConnectionState.disconnected:
        return 'Disconnected';
    }
  }
  int? _deviceBattery;
  int? get deviceBattery => _deviceBattery;

  /// Bumped whenever new content arrives so the view can auto-scroll.
  int revision = 0;

  ChatMessage? _pendingAi;
  ChatMessage? _pendingUserTranscript;
  bool _dropAudio = false;
  StreamSubscription<AdkEvent>? _eventsSub;
  StreamSubscription<Uint8List>? _micSub;
  final Random _rnd = Random();

  bool get canSend => connection == AgentConnection.connected && !sendingMessage;
  bool get isConnected => connection == AgentConnection.connected;

  Future<void> _init() async {
    _eventsSub = _service.events.listen(_onEvent);
    try {
      await _audio.initPlayer();
    } catch (_) {
      // Playback unavailable (e.g. no audio device) — text chat still works.
    }
    await _reconnect(isAudio: false);
  }

  Future<void> _reconnect({required bool isAudio}) async {
    connection = AgentConnection.connecting;
    connectionError = null;
    notifyListeners();
    try {
      await _service.connect(isAudio: isAudio);
    } catch (e) {
      connection = AgentConnection.disconnected;
      connectionError = e.toString();
      notifyListeners();
    }
  }

  /// Manual retry from the UI when the connection is down.
  Future<void> retryConnection() => _reconnect(isAudio: _service.isAudioMode);

  void _onEvent(AdkEvent event) {
    debugPrint('ADK event: $event');
    switch (event) {
      case AdkConnectionChanged(:final connected, :final error):
        connection = connected ? AgentConnection.connected : AgentConnection.disconnected;
        connectionError = error;
      case AdkUserTranscript(:final text, :final isFinal):
        // Stream the user's own speech-to-text into a live user bubble.
        _ensurePendingUserTranscript();
        _pendingUserTranscript!.text =
            _mergeTranscript(_pendingUserTranscript!.text, text, isFinal: isFinal);
        if (isFinal) {
          _pendingUserTranscript!.isComplete = true;
          _pendingUserTranscript = null;
        }
      case AdkTextDelta(:final text, :final isFinal):
        _ensurePendingAi();
        _pendingAi!.text =
            _mergeTranscript(_pendingAi!.text, text, isFinal: isFinal);
        if (isFinal) _pendingAi!.isComplete = true;
      case AdkAudioChunk(:final pcm):
        _ensurePendingAi(voice: true);
        if (!_dropAudio) _audio.feed(pcm);
      case AdkTurnComplete():
        _pendingAi?.isComplete = true;
        _pendingAi = null;
        _pendingUserTranscript?.isComplete = true;
        _pendingUserTranscript = null;
        sendingMessage = false;
        _dropAudio = false;
      case AdkInterrupted():
        // Barge-in: stop routing the current turn's audio to the speaker and
        // drop whatever is already queued so playback halts promptly.
        _dropAudio = true;
        _audio.flush();
      case AdkCaptureImage():
        debugPrint('AdkCaptureImage received; deviceConnected=$deviceConnected');
        if (deviceConnected) {
          _device.capturePhoto().catchError((_) {});
        }
    }
    revision++;
    notifyListeners();
  }

  void _ensurePendingAi({bool voice = false}) {
    if (_pendingAi != null) return;
    final message = ChatMessage(
      id: _newId(),
      sender: MessageSender.ai,
      isComplete: false,
      isVoice: voice,
    );
    _pendingAi = message;
    messages.add(message);
  }

  void _ensurePendingUserTranscript() {
    if (_pendingUserTranscript != null) return;
    final message = ChatMessage(
      id: _newId(),
      sender: MessageSender.user,
      isComplete: false,
      isVoice: true,
    );
    _pendingUserTranscript = message;
    messages.add(message);
  }

  // ---- Composer actions ----------------------------------------------------

  void addAttachment(Attachment attachment) {
    staged.add(attachment);
    notifyListeners();
  }

  void removeAttachment(int index) {
    if (index >= 0 && index < staged.length) {
      staged.removeAt(index);
      notifyListeners();
    }
  }

  Future<void> sendText(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty && staged.isEmpty) return;
    if (!canSend) return;

    final attachments = List<Attachment>.from(staged);
    staged.clear();

    messages.add(ChatMessage(
      id: _newId(),
      sender: MessageSender.user,
      text: text,
      attachments: attachments,
    ));
    sendingMessage = true;
    _dropAudio = false;
    revision++;
    notifyListeners();

    for (final attachment in attachments) {
      try {
        final bytes = await attachment.file.readAsBytes();
        _service.sendBlob(bytes, _mimeFor(attachment));
      } catch (_) {
        // Skip an attachment we can't read; the text still goes through.
      }
    }
    if (text.isNotEmpty) _service.sendText(text);
  }

  // ---- Live voice -----------------------------------------------------------

  Future<void> startVoice() async {
    if (voiceActive) return;
    if (!await _audio.hasMicPermission()) return;

    // Live voice needs the session in audio-response mode.
    if (!_service.isAudioMode) {
      await _reconnect(isAudio: true);
      if (connection != AgentConnection.connected) return;
    }

    _dropAudio = false;
    final stream = await _audio.startMicStream();
    voiceActive = true;
    notifyListeners();
    _micSub = stream.listen(_service.sendAudioChunk);
  }

  Future<void> stopVoice() async {
    if (!voiceActive) return;
    await _micSub?.cancel();
    _micSub = null;
    await _audio.stopMic();
    voiceActive = false;
    sendingMessage = true; // awaiting the agent's spoken reply
    notifyListeners();
  }

  // ---- Device audio (chopper glasses) --------------------------------------

  /// Stream of scanned BLE devices (populated after startDeviceScan).
  StreamSubscription<fbp.BluetoothDevice>? _scanSub;
  StreamSubscription<Uint8List>? _deviceAudioSub;
  StreamSubscription<Uint8List>? _devicePhotoSub;

  /// Callback called when a device is discovered during a scan. The UI
  /// collects these and shows a list.
  void Function(fbp.BluetoothDevice device)? onDeviceDiscovered;

  /// Start scanning for the chopper glasses. Discovered devices are passed
  /// to [onDeviceDiscovered] (set this before calling startDeviceScan).
  Future<void> startDeviceScan() async {
    await _device.ensurePermissions();
    _scanSub?.cancel();
    final stream = _device.scan();
    _scanSub = stream.listen((dev) {
      onDeviceDiscovered?.call(dev);
    });
    notifyListeners();
  }

  void stopDeviceScan() => _device.stopScan();

  /// Connect to the selected device and wire its Opus audio stream into the
  /// ADK path (decoded → PCM16 → sendAudioChunk).
  Future<void> connectToDevice(fbp.BluetoothDevice dev) async {
    _opusDecoder.init();
    try {
      if (!_service.isAudioMode) {
        await _reconnect(isAudio: true);
        if (connection != AgentConnection.connected) {
          return;
        }
      }

      _deviceAudioSub?.cancel();
      _deviceAudioSub = null;
      _devicePhotoSub?.cancel();
      _devicePhotoSub = null;

      await _device.connect(dev);

      await FlutterForegroundTask.startService(
        notificationTitle: 'Chopper connected',
        notificationText: 'BLE + WebSocket + Audio streaming',
      );

      // Battery listener
      _device.batteryLevel.listen((level) {
        _deviceBattery = level;
        notifyListeners();
      });

      // Wire Opus frames → decode → send to ADK
      _deviceAudioSub = _device.opusFrames.listen((opusFrame) {
        try {
          final pcm = _opusDecoder.decode(opusFrame);
          if (pcm.isNotEmpty) {
            _service.sendAudioChunk(pcm);
          }
        } catch (_) {
          // Single corrupt frame — drop it, keep streaming.
        }
      });

      // Wire reassembled JPEGs from the glasses → send to server as blobs.
      _devicePhotoSub = _device.photoData.listen((jpeg) {
        _service.sendBlob(jpeg, 'image/jpeg');
      });
    } catch (e, s) {
      // Connection or codec mismatch — surface in UI via deviceState stream.
      debugPrint('connectToDevice error: $e\n$s');
    }
  }

  Future<void> disconnectDevice() async {
    await _deviceAudioSub?.cancel();
    _deviceAudioSub = null;
    await _devicePhotoSub?.cancel();
    _devicePhotoSub = null;
    await _device.disconnect();
    await FlutterForegroundTask.stopService();
    _deviceBattery = null;
    notifyListeners();
  }

  // ---- Phone mic voice ------------------------------------------------------

  Future<void> cancelVoice() async {
    await _micSub?.cancel();
    _micSub = null;
    await _audio.stopMic();
    voiceActive = false;
    notifyListeners();
  }

  // ---- Helpers --------------------------------------------------------------

  /// Folds a streamed transcription chunk into the text accumulated so far,
  /// mirroring the reference web client (`useLiveConnection.ts`):
  ///   - partial chunks (`is_final:false`) are trimmed and space-joined;
  ///   - a final chunk (`is_final:true`) carries the *entire* transcription and
  ///     therefore replaces everything accumulated so far — appending it would
  ///     duplicate the whole sentence.
  /// Gemini control tokens like `<ctrl99>` occasionally leak into the text and
  /// are stripped.
  static final RegExp _ctrlToken = RegExp(r'<ctrl\d+>', caseSensitive: false);

  String _mergeTranscript(String current, String incoming, {required bool isFinal}) {
    final text = incoming.replaceAll(_ctrlToken, '').trim();
    if (isFinal) return text.isEmpty ? current : text;
    if (text.isEmpty) return current;
    return current.isEmpty ? text : '$current $text';
  }

  String _mimeFor(Attachment a) {
    switch (a.type) {
      case AttachmentType.image:
        final n = a.name.toLowerCase();
        if (n.endsWith('.png')) return 'image/png';
        if (n.endsWith('.webp')) return 'image/webp';
        if (n.endsWith('.gif')) return 'image/gif';
        return 'image/jpeg';
      case AttachmentType.audio:
        return 'audio/pcm';
      case AttachmentType.file:
        return 'application/octet-stream';
    }
  }

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}-${_rnd.nextInt(1 << 31)}';

  @override
  void dispose() {
    unawaited(FlutterForegroundTask.stopService());
    _eventsSub?.cancel();
    _micSub?.cancel();
    _scanSub?.cancel();
    _deviceAudioSub?.cancel();
    _devicePhotoSub?.cancel();
    _device.dispose();
    _opusDecoder.dispose();
    _service.dispose();
    _audio.dispose();
    super.dispose();
  }
}

