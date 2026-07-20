import 'dart:async';
import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/chat_message.dart';
import '../services/adk_agent_service.dart';
import '../services/app_log.dart';
import '../services/audio_io.dart';
import '../services/mjpeg_stream.dart';
import '../services/omi_device_service.dart';
import '../services/opus_audio_decoder.dart';

enum AgentConnection { connecting, connected, disconnected }

/// Which transport carries captured photos from the glasses to the app.
enum PhotoTransport { ble, wifi }

/// Rotate a JPEG by [degrees] clockwise, re-encoding as JPEG. Top-level so it
/// can run in an isolate via [compute] — decoding a VGA frame off the UI thread
/// keeps audio playback smooth. Returns the input unchanged on a no-op (0°) or
/// decode failure, so a bad frame is still delivered rather than dropped.
Uint8List _rotateJpegIsolate((Uint8List, int) arg) {
  final (bytes, degrees) = arg;
  final norm = ((degrees % 360) + 360) % 360;
  if (norm == 0) return bytes;
  final decoded = img.decodeJpg(bytes);
  if (decoded == null) return bytes;
  final rotated = img.copyRotate(decoded, angle: norm);
  return img.encodeJpg(rotated, quality: 85);
}

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

  /// Last device-connection error, surfaced to the UI (null when none).
  String? deviceError;

  // ---- Photo transport (BLE vs WiFi) ---------------------------------------

  PhotoTransport _photoTransport = PhotoTransport.ble;
  PhotoTransport get photoTransport => _photoTransport;

  String _wifiSsid = '';
  String _wifiPassword = '';
  String get wifiSsid => _wifiSsid;
  String get wifiPassword => _wifiPassword;

  // Persisted-settings keys + a cached SharedPreferences instance (obtained once).
  static const String _kWifiSsid = 'wifi_ssid';
  static const String _kWifiPassword = 'wifi_password';
  static const String _kPhotoTransport = 'photo_transport';
  SharedPreferences? _prefs;
  Future<SharedPreferences> _prefsInstance() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Live WiFi photo-transport status/IP from the device (over BLE).
  WifiPhotoStatus get wifiPhotoStatus => _device.wifiPhotoStatus;
  String? get wifiIp => _device.wifiIp;

  StreamSubscription<WifiPhotoStatus>? _wifiStatusSub;

  // ---- Live video (MJPEG over WiFi) ----------------------------------------
  // Owned here (not in VideoPage) so the capture path can snapshot the latest
  // frame while streaming — avoiding a second camera consumer on the device.
  // MJPEG stream port on the device (firmware WIFI_STREAM_HTTP_PORT).
  static const int _streamPort = 81;
  final MjpegStream _video = MjpegStream();
  ValueListenable<Uint8List?> get videoFrame => _video.frame;
  ValueListenable<bool> get videoRunning => _video.running;
  ValueListenable<String?> get videoError => _video.error;
  bool get isStreaming => _video.running.value;
  Uint8List? get lastVideoFrame => _video.frame.value;

  /// Open the device's MJPEG stream (requires WiFi connected). Throws if no IP.
  Future<void> startVideo() async {
    final ip = _device.wifiIp;
    if (ip == null) {
      throw StateError('Device WiFi not connected');
    }
    await _video.start('http://$ip:$_streamPort/stream');
    notifyListeners();
  }

  /// Stop the live stream.
  Future<void> stopVideo() async {
    await _video.stop();
    notifyListeners();
  }

  /// Bumped whenever new content arrives so the view can auto-scroll.
  int revision = 0;

  ChatMessage? _pendingAi;
  ChatMessage? _pendingUserTranscript;
  bool _dropAudio = false;
  StreamSubscription<AdkEvent>? _eventsSub;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<DeviceConnectionState>? _deviceStateSub;
  final Random _rnd = Random();

  bool get canSend => connection == AgentConnection.connected && !sendingMessage;
  bool get isConnected => connection == AgentConnection.connected;

  Future<void> _init() async {
    _eventsSub = _service.events.listen(_onEvent);
    // Rebuild the UI whenever the glasses' BLE state changes so the status
    // text reflects connecting/connected/error live.
    _deviceStateSub = _device.connectionState.listen((state) {
      AppLog.instance.add('BLE state: ${state.name}');
      notifyListeners();
    });
    // Reflect device WiFi status/IP changes in the UI live.
    _wifiStatusSub = _device.wifiStatus.listen((_) => notifyListeners());
    await _loadPreferences();
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
        if (!connected) {
          sendingMessage = false;
        }
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
        AppLog.instance.add(
            '📸 capture_image received (connected=$deviceConnected, transport=${_photoTransport.name}, streaming=$isStreaming)');
        if (deviceConnected) {
          if (isStreaming) {
            // Live video owns the camera on the device (a /photo or BLE capture
            // would be refused/queued). Snapshot the frame we already have, or
            // skip if the first frame hasn't decoded yet — never fall through.
            final snapshot = lastVideoFrame;
            if (snapshot != null) {
              // NOTE: this is the stream resolution (CIF ~400x296), lower than a
              // dedicated VGA still — the agent's vision input is degraded here.
              AppLog.instance.add('📸 snapshot from live video (CIF, ${snapshot.length} bytes)');
              // MJPEG frames carry no orientation byte; use the device default.
              _sendOrientedPhoto(snapshot, kDefaultPhotoOrientationDegrees);
            } else {
              AppLog.instance.add('📸 capture skipped: live stream has no frame yet');
            }
          } else if (_photoTransport == PhotoTransport.wifi) {
            // WiFi mode is strict: no silent fallback to BLE — surface errors.
            _device.capturePhotoOverWifi().catchError((e) {
              AppLog.instance.add('📸 wifi capture error: $e');
            });
          } else {
            _device.capturePhoto().catchError((_) {});
          }
        } else {
          AppLog.instance.add('📸 ignored: glasses not connected');
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

    // Safety timeout: re-enable send button if the agent takes more than 4 seconds to finish its turn
    Timer(const Duration(seconds: 4), () {
      if (sendingMessage) {
        sendingMessage = false;
        notifyListeners();
      }
    });

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

    // Safety timeout: re-enable send button if the agent takes more than 4 seconds to finish its turn
    Timer(const Duration(seconds: 4), () {
      if (sendingMessage) {
        sendingMessage = false;
        notifyListeners();
      }
    });
  }

  // ---- Device audio (chopper glasses) --------------------------------------

  /// Stream of scanned BLE devices (populated after startDeviceScan).
  StreamSubscription<fbp.BluetoothDevice>? _scanSub;
  StreamSubscription<Uint8List>? _deviceAudioSub;
  StreamSubscription<DevicePhoto>? _devicePhotoSub;

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
    deviceError = null;
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

      // Wire reassembled JPEGs from the glasses → rotate to the correct
      // orientation → send to server as blobs.
      _devicePhotoSub = _device.photoData.listen((photo) {
        _sendOrientedPhoto(photo.bytes, photo.orientationDegrees);
      });
    } catch (e, s) {
      // Connection or codec mismatch — surface in UI via deviceState stream.
      debugPrint('connectToDevice error: $e\n$s');
      AppLog.instance.add('❌ connect failed: $e');
      deviceError = e.toString();
      notifyListeners();
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

  // ---- WiFi photo transport -------------------------------------------------

  /// Switch the photo transport between BLE and WiFi (persisted).
  Future<void> setPhotoTransport(PhotoTransport transport) async {
    _photoTransport = transport;
    notifyListeners();
    try {
      final prefs = await _prefsInstance();
      await prefs.setString(_kPhotoTransport, transport.name);
    } catch (_) {}
  }

  /// Save WiFi credentials and ask the connected device to join the network and
  /// bring up its HTTP photo server. Credentials are persisted for next time.
  Future<void> enableWifi(String ssid, String password) async {
    _wifiSsid = ssid;
    _wifiPassword = password;
    await _persistWifiCredentials();
    notifyListeners();
    await _device.connectWifi(ssid, password);
  }

  /// Ask the device to drop WiFi and stop its HTTP server.
  Future<void> disableWifi() async {
    await _device.disconnectWifi();
    notifyListeners();
  }

  Future<void> _persistWifiCredentials() async {
    try {
      final prefs = await _prefsInstance();
      await prefs.setString(_kWifiSsid, _wifiSsid);
      await prefs.setString(_kWifiPassword, _wifiPassword);
    } catch (_) {}
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await _prefsInstance();
      _wifiSsid = prefs.getString(_kWifiSsid) ?? '';
      _wifiPassword = prefs.getString(_kWifiPassword) ?? '';
      _photoTransport = prefs.getString(_kPhotoTransport) == PhotoTransport.wifi.name
          ? PhotoTransport.wifi
          : PhotoTransport.ble;
      AppConfig.customWsUrl = prefs.getString('custom_ws_url') ?? '';
      notifyListeners();
    } catch (_) {
      // Preferences unavailable — fall back to BLE defaults.
    }
  }

  String get customWsUrl => AppConfig.customWsUrl ?? '';

  Future<void> setCustomWsUrl(String url) async {
    AppConfig.customWsUrl = url.trim();
    notifyListeners();
    try {
      final prefs = await _prefsInstance();
      await prefs.setString('custom_ws_url', AppConfig.customWsUrl!);
    } catch (_) {}
    unawaited(_reconnect(isAudio: _service.isAudioMode));
  }

  // ---- Phone mic voice ------------------------------------------------------

  Future<void> cancelVoice() async {
    await _micSub?.cancel();
    _micSub = null;
    await _audio.stopMic();
    voiceActive = false;
    notifyListeners();
  }

  /// Rotate a captured JPEG to the correct orientation (off the UI thread),
  /// then forward it to the agent and add it to the chat. Rotation failures
  /// fall back to the raw bytes so a capture is never silently lost.
  Future<void> _sendOrientedPhoto(Uint8List jpeg, int degrees) async {
    Uint8List oriented = jpeg;
    try {
      oriented = await compute(_rotateJpegIsolate, (jpeg, degrees));
    } catch (e) {
      AppLog.instance.add('📸 rotate failed ($degrees°): $e');
    }
    AppLog.instance.add('📸 photo sent to agent: ${oriented.length} bytes');
    _service.sendBlob(oriented, 'image/jpeg');
    _handleDevicePhoto(oriented);
  }

  Future<void> _handleDevicePhoto(Uint8List jpeg) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final filename = 'captured_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file = io.File('${tempDir.path}/$filename');
      await file.writeAsBytes(jpeg);

      messages.add(ChatMessage(
        id: _newId(),
        sender: MessageSender.user,
        attachments: [
          Attachment(
            path: file.path,
            name: filename,
            type: AttachmentType.image,
          ),
        ],
      ));
      revision++;
      notifyListeners();
    } catch (e) {
      AppLog.instance.add('❌ failed to save captured photo: $e');
    }
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
    _deviceStateSub?.cancel();
    _wifiStatusSub?.cancel();
    _video.dispose();
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


