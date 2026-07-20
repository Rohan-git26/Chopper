import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore_for_file: constant_identifier_names
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_log.dart';
import 'http_util.dart';

// UUIDs — must match omiGlass/firmware/src/config.h exactly.
const String _serviceUuid = '19B10000-E8F2-537E-4F6C-D104768A1214';
const String _audioCharUuid = '19B10001-E8F2-537E-4F6C-D104768A1214';
const String _codecCharUuid = '19B10002-E8F2-537E-4F6C-D104768A1214';
const String _photoDataUuid = '19B10005-E8F2-537E-4F6C-D104768A1214';
const String _photoControlUuid = '19B10006-E8F2-537E-4F6C-D104768A1214';
const String _batteryServiceUuid = '0000180F-0000-1000-8000-00805F9B34FB';
const String _batteryCharUuid = '00002A19-0000-1000-8000-00805F9B34FB';

/// Connection state of the chopper glasses.
enum DeviceConnectionState { disconnected, scanning, connecting, connected, error }

/// WiFi photo-transport state, mirrored from the device over BLE.
enum WifiPhotoStatus { disconnected, connecting, connected, failed }

/// A reassembled JPEG from the glasses plus the rotation (in degrees clockwise)
/// that should be applied before use. The firmware ships an orientation hint on
/// the BLE path (`config.h` `FIXED_IMAGE_ORIENTATION`, currently 180°); transports
/// without a hint (WiFi `/photo`) fall back to [kDefaultPhotoOrientationDegrees].
class DevicePhoto {
  DevicePhoto(this.bytes, this.orientationDegrees);
  final Uint8List bytes;
  final int orientationDegrees;
}

/// Rotation to assume when the transport carries no orientation byte. The camera
/// is physically mounted the same way regardless of transport, so this mirrors
/// the firmware's fixed BLE orientation (180°). Also used by the live-video
/// snapshot path, whose MJPEG frames carry no orientation metadata either.
const int kDefaultPhotoOrientationDegrees = 180;

// WiFi photo protocol — must match firmware/src/wifi_photo.h.
const int _wifiCmdSetWifi = 0x10; // [0x10, ssidLen, ssid..., passLen, pass...]
const int _wifiCmdDisconnect = 0x11; // [0x11]
const int _wifiStatusMarker = 0xF1; // photo-data frame prefix for status
const int _wifiStConnecting = 0x01;
const int _wifiStConnected = 0x02; // followed by ASCII IP
const int _wifiStFailed = 0x03;

/// Manages the BLE lifecycle for the chopper wearable glasses.
///
/// Usage:
/// ```
/// final svc = OmiDeviceService();
/// await svc.startScan();              // listens for _scanResultController
/// await svc.connect(device);          // connect to a discovered device
/// // Decoded device audio available via svc.opusFrames
/// // Battery updates via svc.batteryLevel
/// await svc.disconnect();
/// ```
class OmiDeviceService {
  BluetoothDevice? _device;
  StreamSubscription? _connectionSub;
  StreamSubscription? _audioSub;
  StreamSubscription? _batterySub;
  StreamSubscription? _photoDataSub;

  final _stateController = StreamController<DeviceConnectionState>.broadcast();
  final _opusFrameController = StreamController<Uint8List>.broadcast();
  final _batteryController = StreamController<int>.broadcast();
  final _photoDataController = StreamController<DevicePhoto>.broadcast();
  final _wifiStatusController = StreamController<WifiPhotoStatus>.broadcast();

  Stream<DeviceConnectionState> get connectionState => _stateController.stream;
  Stream<Uint8List> get opusFrames => _opusFrameController.stream;
  Stream<int> get batteryLevel => _batteryController.stream;
  Stream<DevicePhoto> get photoData => _photoDataController.stream;

  /// WiFi photo-transport status, reported by the device over BLE.
  Stream<WifiPhotoStatus> get wifiStatus => _wifiStatusController.stream;

  WifiPhotoStatus _wifiPhotoStatus = WifiPhotoStatus.disconnected;
  String? _wifiIp;

  /// Current WiFi photo-transport status (last value seen from the device).
  WifiPhotoStatus get wifiPhotoStatus => _wifiPhotoStatus;

  /// The device's WiFi IP address once connected (null otherwise). This is the
  /// host used for `GET http://<ip>/photo`.
  String? get wifiIp => _wifiIp;

  DeviceConnectionState _currentState = DeviceConnectionState.disconnected;
  String? _lastError;

  // App-level auto-reconnect. flutter_blue_plus's autoConnect:true is avoided —
  // it requires mtu:null, never times out, and must call requestMtu after
  // connect (which previously misbehaved). The plugin docs recommend simply
  // calling connect() again on an unexpected drop, which is what we do here.
  bool _userDisconnect = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _stabilityTimer;
  static const int _maxReconnectAttempts = 5;
  static const Duration _stabilityWindow = Duration(seconds: 20);

  String? get lastError => _lastError;
  DeviceConnectionState get currentState => _currentState;

  // Photo reassembly state
  final List<int> _photoBuffer = <int>[];
  bool _photoInProgress = false;
  int? _photoOrientation;

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Start scanning for the chopper glasses. Returns a stream of discovered
  /// devices (typically a single peripheral). Call [stopScan] when satisfied.
  ///
  /// The scan filters by the OMI service UUID; in production the device also
  /// advertises the name "chopper" once the firmware config.h change is
  /// flashed.
  Future<void> ensurePermissions() async {
    if (!Platform.isAndroid) return;

    // Request as a LIST in a single call. Android serializes permission
    // dialogs, so requesting each permission concurrently (Future.wait of
    // separate .request() calls) races the activity-result channel — only the
    // first dialog shows and the rest are silently returned as denied without
    // ever prompting (previously location never appeared until an app restart).
    // permission_handler's batch request shows the dialogs one after another.
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final denied =
        statuses.values.any((status) => status.isDenied || status.isPermanentlyDenied);
    if (denied) {
      throw StateError('BLE permissions were denied. Please allow Bluetooth and location access.');
    }
  }

  Stream<BluetoothDevice> scan() {
    _setState(DeviceConnectionState.scanning);

    // Use withServices to filter at the OS level. flutter_blue_plus will
    // request the scan permission automatically on Android 12+.
    FlutterBluePlus.startScan(
      withServices: [Guid(_serviceUuid)],
      timeout: const Duration(seconds: 15),
    );

    return FlutterBluePlus.scanResults.map((results) {
      for (var sr in results) {
        final dev = sr.device;
        if (dev.platformName.toLowerCase().contains('chopper')) {
          return dev;
        }
      }
      return null;
    }).where((dev) => dev != null).cast<BluetoothDevice>();
  }

  void stopScan() {
    FlutterBluePlus.stopScan();
    if (_currentState == DeviceConnectionState.scanning) {
      _setState(DeviceConnectionState.disconnected);
    }
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  /// Connect, discover services, request MTU=517, read codec, enable audio
  /// notifications, and expose the resulting opus-frame stream.
  ///
  /// Throws if the device advertises a codec other than 21 (Opus).
  Future<void> connect(BluetoothDevice device, {bool isRetry = false}) async {
    await ensurePermissions();

    if (_currentState == DeviceConnectionState.connected) {
      await disconnect();
    }

    // This is a deliberate (re)connect attempt — clear the user-disconnect flag
    // set by disconnect() and cancel any pending reconnect timer.
    _userDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    // A user-initiated connect gets a fresh retry budget; auto-retries keep the
    // running count so the cap can be reached.
    if (!isRetry) _reconnectAttempts = 0;

    _device = device;
    _lastError = null;
    _setState(DeviceConnectionState.connecting);

    try {
      // Listen for connection state changes so we can react to unexpected
      // disconnects (walked out of range, device powered off, etc.).
      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            _currentState == DeviceConnectionState.connected) {
          _setState(DeviceConnectionState.disconnected);
          // The link didn't stay up long enough to prove stable — don't let the
          // pending stability reset clear the retry budget for this flap.
          _stabilityTimer?.cancel();
          _cleanup();
          // Auto-reconnect on an *unexpected* drop (out of range / power cycle).
          if (!_userDisconnect) _scheduleReconnect(device);
        }
      });

      // Connect and wait until the link is actually established. NOTE:
      // autoConnect must be false here — with autoConnect:true, connect()
      // returns before the device is connected AND requestMtu() is not
      // supported (it throws), which silently breaks the whole flow.
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 15));

      // Negotiate maximum MTU (517 is the highest the ESP32-S3 reliably
      // supports; 185 is the default and far too small for Opus frames).
      await device.requestMtu(517);

      final services = await device.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == Guid(_serviceUuid),
        orElse: () => throw StateError('OMI service not found'),
      );

      // Read codec characteristic — must be 21 (Opus).
      final codecChar = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(_codecCharUuid),
        orElse: () => throw StateError('Codec characteristic not found'),
      );
      final codecValue = await codecChar.read();
      if (codecValue.isNotEmpty && codecValue[0] != 21) {
        throw StateError('Unsupported codec: ${codecValue[0]} (expected 21/Opus)');
      }

      // Belt-and-suspenders: write 0x00 to photo control to stop any
      // auto-capture that may have been started by the firmware.
      final photoControl = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(_photoControlUuid),
        orElse: () => throw StateError('Photo control characteristic not found'),
      );
      await photoControl.write([0x00], withoutResponse: false);

      // Subscribe to audio notifications. Each frame: [idx_lo, idx_hi, 0] + opus.
      final audioChar = service.characteristics.firstWhere(
        (c) => c.uuid == Guid(_audioCharUuid),
        orElse: () => throw StateError('Audio characteristic not found'),
      );
      await audioChar.setNotifyValue(true);
      _audioSub = audioChar.lastValueStream.listen(_onAudioNotify);

      // Subscribe to photo data notifications (19B10005) for JPEG reassembly.
      try {
        final photoDataChar = service.characteristics.firstWhere(
          (c) => c.uuid == Guid(_photoDataUuid),
        );
        await photoDataChar.setNotifyValue(true);
        _photoDataSub = photoDataChar.lastValueStream.listen(_onPhotoNotify);
      } catch (_) {
        // Photo data characteristic is optional — some firmwares omit it.
      }

      // Subscribe to battery level notifications (0x180F/0x2A19).
      try {
        final batteryService = services.firstWhere(
          (s) => s.uuid == Guid(_batteryServiceUuid),
        );
        final batteryChar = batteryService.characteristics.firstWhere(
          (c) => c.uuid == Guid(_batteryCharUuid),
        );
        await batteryChar.setNotifyValue(true);
        _batterySub = batteryChar.lastValueStream.listen((value) {
          if (value.isNotEmpty) _batteryController.add(value[0]);
        });
      } catch (_) {
        // Battery service is optional — some firmware builds omit it.
      }

      // Only reset the reconnect budget once the link has proven STABLE for a
      // while. Resetting immediately on connect would let a device that connects
      // then instantly drops (flaps) reconnect forever without ever hitting the cap.
      _stabilityTimer?.cancel();
      _stabilityTimer = Timer(_stabilityWindow, () => _reconnectAttempts = 0);
      _setState(DeviceConnectionState.connected);
    } catch (e) {
      // Surface the failure instead of leaving the state stuck at
      // "connecting". Tear down the half-open connection and expose the error.
      _lastError = e.toString();
      try {
        await device.disconnect();
      } catch (_) {}
      _cleanup();
      _setState(DeviceConnectionState.error);
      rethrow;
    }
  }

  /// Disconnect and release all resources. Marks the disconnect as
  /// user-initiated so auto-reconnect does NOT kick in.
  Future<void> disconnect() async {
    _userDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stabilityTimer?.cancel();
    _stabilityTimer = null;
    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {}
    }
    _cleanup();
    _setState(DeviceConnectionState.disconnected);
  }

  /// Retry connect() after an *unexpected* drop, with linear backoff, up to
  /// [_maxReconnectAttempts]. Aborted if the user disconnects meanwhile.
  void _scheduleReconnect(BluetoothDevice device) {
    if (_userDisconnect) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      AppLog.instance.add('❌ reconnect gave up after $_maxReconnectAttempts tries');
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(seconds: 2 * _reconnectAttempts);
    AppLog.instance.add('🔄 reconnect #$_reconnectAttempts in ${delay.inSeconds}s');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (_userDisconnect) return;
      try {
        await connect(device, isRetry: true);
      } catch (_) {
        // connect() already surfaced the error; queue the next attempt.
        if (!_userDisconnect) _scheduleReconnect(device);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Photo capture (Phase 3)
  // ---------------------------------------------------------------------------

  /// Trigger a single photo capture. Writes a single byte `0xFF` (-1) to the
  /// photo control characteristic. The resulting JPEG is reassembled from
  /// `photoData` notifications.
  ///
  /// NOTE: this MUST be a single byte. The firmware's PhotoControlCallback only
  /// acts on writes of length 1 (`getLength() == 1`) and reads it as an int8,
  /// where -1 (0xFF) = single photo. A 2-byte write is silently ignored, so the
  /// camera never fires.
  Future<void> capturePhoto() async {
    try {
      final photoControl = await _photoControlChar();
      // Single-byte 0xFF (-1 as int8) = single-shot capture command.
      await photoControl.write([0xFF], withoutResponse: false);
      AppLog.instance.add('📸 capture trigger sent to device');
    } catch (e) {
      AppLog.instance.add('📸 capture trigger FAILED: $e');
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _onAudioNotify(List<int> value) {
    if (value.length <= 3) return;
    // Strip 3-byte header: [index_lo, index_hi, 0]
    final opusFrame = Uint8List.fromList(value.sublist(3));
    if (opusFrame.isNotEmpty) {
      _opusFrameController.add(opusFrame);
    }
  }

  /// Reassemble JPEG from photo data notifications.
  /// Frame format: [index_lo, index_hi, ...data].
  ///   - frameIndex 0: first frame; byte [2] = orientation (fw ≥2.1.1).
  ///   - frameIndex 0xFFFF: end-of-transfer marker.
  void _onPhotoNotify(List<int> value) {
    if (value.length < 2) return;

    // WiFi status frames are multiplexed onto this characteristic, prefixed with
    // a TWO-byte 0xF1 0xF1 magic. Two bytes can't alias a photo frame index
    // (index 0xF1F1 would need a >30 MB image), unlike a single 0xF1 which
    // collided with chunk #241.
    if (value.length >= 3 && value[0] == _wifiStatusMarker && value[1] == _wifiStatusMarker) {
      _handleWifiStatus(value);
      return;
    }

    final frameIndex = value[0] | (value[1] << 8);

    if (frameIndex == 0xFFFF) {
      // End-of-transfer: append trailing data, if any, and emit.
      if (value.length > 2) {
        _photoBuffer.addAll(value.sublist(2));
      }
      _emitPhoto();
      return;
    }

    if (frameIndex == 0) {
      // First frame: begin new reassembly.
      AppLog.instance.add('📸 photo transfer started');
      _photoBuffer.clear();
      _photoInProgress = true;
      // Orientation is at byte [2] on fw ≥2.1.1; data starts after.
      _photoOrientation = value.length > 2 ? value[2] : null;
      final dataOffset = (value.length > 2 ? 3 : 2);
      if (value.length > dataOffset) {
        _photoBuffer.addAll(value.sublist(dataOffset));
      }
      return;
    }

    // Continuation frame: append data after the 2-byte header.
    if (_photoInProgress && value.length > 2) {
      _photoBuffer.addAll(value.sublist(2));
    }
  }

  void _emitPhoto() {
    if (!_photoInProgress || _photoBuffer.isEmpty) return;
    // Firmware orientation byte is an enum ordinal (0/1/2/3 => 0/90/180/270°).
    // Absent (older fw / non-BLE) => assume the device's fixed orientation.
    final degrees =
        _photoOrientation != null ? (_photoOrientation! * 90) % 360 : kDefaultPhotoOrientationDegrees;
    AppLog.instance.add('📸 photo assembled: ${_photoBuffer.length} bytes (rotate $degrees°)');
    _photoDataController.add(DevicePhoto(Uint8List.fromList(_photoBuffer), degrees));
    _photoBuffer.clear();
    _photoInProgress = false;
    _photoOrientation = null;
  }

  /// Parse a WiFi status frame: [0xF1, 0xF1, status, <ascii ip if connected>].
  void _handleWifiStatus(List<int> value) {
    if (value.length < 3) return;
    switch (value[2]) {
      case _wifiStConnecting:
        _wifiPhotoStatus = WifiPhotoStatus.connecting;
        _wifiIp = null;
        AppLog.instance.add('📶 device WiFi connecting…');
      case _wifiStConnected:
        _wifiIp = value.length > 3 ? String.fromCharCodes(value.sublist(3)) : null;
        _wifiPhotoStatus = WifiPhotoStatus.connected;
        AppLog.instance.add('📶 device WiFi connected: ${_wifiIp ?? '?'}');
      case _wifiStFailed:
        _wifiPhotoStatus = WifiPhotoStatus.failed;
        _wifiIp = null;
        AppLog.instance.add('📶 device WiFi failed');
      default: // _wifiStDisconnected (0x00) or unknown
        _wifiPhotoStatus = WifiPhotoStatus.disconnected;
        _wifiIp = null;
        AppLog.instance.add('📶 device WiFi disconnected');
    }
    _wifiStatusController.add(_wifiPhotoStatus);
  }

  // ---------------------------------------------------------------------------
  // WiFi photo transport
  // ---------------------------------------------------------------------------

  Future<BluetoothCharacteristic> _photoControlChar() async {
    if (_device == null || _currentState != DeviceConnectionState.connected) {
      throw StateError('Device not connected');
    }
    final services = await _device!.discoverServices();
    final service = services.firstWhere((s) => s.uuid == Guid(_serviceUuid));
    return service.characteristics.firstWhere(
      (c) => c.uuid == Guid(_photoControlUuid),
    );
  }

  /// Send WiFi credentials to the device, asking it to join the network and
  /// start its HTTP photo server. Progress arrives via [wifiStatus] / [wifiIp].
  Future<void> connectWifi(String ssid, String password) async {
    final ssidBytes = utf8.encode(ssid);
    final passBytes = utf8.encode(password);
    if (ssidBytes.length > 32) throw StateError('SSID too long (max 32)');
    if (passBytes.length > 64) throw StateError('Password too long (max 64)');

    final payload = <int>[
      _wifiCmdSetWifi,
      ssidBytes.length,
      ...ssidBytes,
      passBytes.length,
      ...passBytes,
    ];
    _wifiPhotoStatus = WifiPhotoStatus.connecting;
    _wifiStatusController.add(_wifiPhotoStatus);
    try {
      final photoControl = await _photoControlChar();
      await photoControl.write(payload, withoutResponse: false);
      AppLog.instance.add('📶 wifi credentials sent (ssid="$ssid")');
    } catch (e) {
      // The command never reached the device, so no status frame will ever
      // arrive — reset out of "connecting" so the UI doesn't hang there.
      _wifiPhotoStatus = WifiPhotoStatus.failed;
      _wifiStatusController.add(_wifiPhotoStatus);
      AppLog.instance.add('📶 wifi connect send FAILED: $e');
      rethrow;
    }
  }

  /// Ask the device to drop WiFi and stop its HTTP server.
  Future<void> disconnectWifi() async {
    final photoControl = await _photoControlChar();
    // Must be >= 2 bytes: the firmware routes single-byte photo-control writes
    // to the legacy capture handler (where 0x11 = 17 would start interval
    // capture), and only multi-byte writes to the WiFi command handler.
    await photoControl.write([_wifiCmdDisconnect, 0x00], withoutResponse: false);
    _wifiPhotoStatus = WifiPhotoStatus.disconnected;
    _wifiIp = null;
    _wifiStatusController.add(_wifiPhotoStatus);
    AppLog.instance.add('📶 wifi disconnect sent');
  }

  /// Fetch a photo over HTTP (`GET http://<deviceIp>/photo`) and emit it on the
  /// same [photoData] stream the BLE path uses, so downstream handling is
  /// identical regardless of transport.
  Future<void> capturePhotoOverWifi() async {
    final ip = _wifiIp;
    if (ip == null || _wifiPhotoStatus != WifiPhotoStatus.connected) {
      AppLog.instance.add('📸 wifi capture skipped: device WiFi not connected');
      throw StateError('Device WiFi not connected');
    }
    HttpClient? client;
    try {
      AppLog.instance.add('📸 wifi GET http://$ip/photo');
      client = HttpClient();
      final response = await httpGetOk(client, 'http://$ip/photo');
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      AppLog.instance.add('📸 wifi photo received: ${bytes.length} bytes');
      // The WiFi /photo path carries no orientation byte; assume the device's
      // fixed orientation so downstream rotation matches the BLE path.
      _photoDataController.add(DevicePhoto(Uint8List.fromList(bytes), kDefaultPhotoOrientationDegrees));
    } catch (e) {
      AppLog.instance.add('📸 wifi capture FAILED: $e');
      rethrow;
    } finally {
      client?.close(force: true);
    }
  }

  void _setState(DeviceConnectionState state) {
    _currentState = state;
    _stateController.add(state);
  }

  void _cleanup() {
    _audioSub?.cancel();
    _audioSub = null;
    _photoDataSub?.cancel();
    _photoDataSub = null;
    _batterySub?.cancel();
    _batterySub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _device = null;
    _photoBuffer.clear();
    _photoInProgress = false;
    _photoOrientation = null;
    _wifiPhotoStatus = WifiPhotoStatus.disconnected;
    _wifiIp = null;
  }

  void dispose() {
    _userDisconnect = true; // prevent any queued reconnect after dispose
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stabilityTimer?.cancel();
    _stabilityTimer = null;
    _cleanup();
    _stateController.close();
    _opusFrameController.close();
    _batteryController.close();
    _photoDataController.close();
    _wifiStatusController.close();
  }
}

