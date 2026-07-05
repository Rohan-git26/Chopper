import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// ignore_for_file: constant_identifier_names
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final _photoDataController = StreamController<Uint8List>.broadcast();

  Stream<DeviceConnectionState> get connectionState => _stateController.stream;
  Stream<Uint8List> get opusFrames => _opusFrameController.stream;
  Stream<int> get batteryLevel => _batteryController.stream;
  Stream<Uint8List> get photoData => _photoDataController.stream;

  DeviceConnectionState _currentState = DeviceConnectionState.disconnected;
  String? _lastError;

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

    final statuses = await Future.wait([
      Permission.bluetoothScan.request(),
      Permission.bluetoothConnect.request(),
      Permission.locationWhenInUse.request(),
    ]);

    final denied = statuses.where((status) => status.isDenied || status.isPermanentlyDenied).isNotEmpty;
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
  Future<void> connect(BluetoothDevice device) async {
    await ensurePermissions();

    if (_currentState == DeviceConnectionState.connected) {
      await disconnect();
    }

    _device = device;
    _setState(DeviceConnectionState.connecting);

    // Listen for connection state changes so we can react to unexpected
    // disconnects (walked out of range, device powered off, etc.).
    _connectionSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _setState(DeviceConnectionState.disconnected);
        _cleanup();
      }
    });

    // Connect with auto-connect semantics (the OS will re-connect when the
    // device comes back in range, useful for background operation).',
    await device.connect(autoConnect: true);

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

    _setState(DeviceConnectionState.connected);
  }

  /// Disconnect and release all resources.
  Future<void> disconnect() async {
    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {}
    }
    _cleanup();
    _setState(DeviceConnectionState.disconnected);
  }

  // ---------------------------------------------------------------------------
  // Photo capture (Phase 3)
  // ---------------------------------------------------------------------------

  /// Trigger a single photo capture. Writes `-1` (0xFFFF as LE int16) to the
  /// photo control characteristic. The resulting JPEG is reassembled from
  /// `photoData` notifications.
  Future<void> capturePhoto() async {
    if (_device == null || _currentState != DeviceConnectionState.connected) {
      throw StateError('Device not connected');
    }
    final services = await _device!.discoverServices();
    final service = services.firstWhere((s) => s.uuid == Guid(_serviceUuid));
    final photoControl = service.characteristics.firstWhere(
      (c) => c.uuid == Guid(_photoControlUuid),
    );
    // Write 0xFFFF as two-byte little-endian (single-shot trigger).
    await photoControl.write([0xFF, 0xFF], withoutResponse: false);
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
    _photoDataController.add(Uint8List.fromList(_photoBuffer));
    _photoBuffer.clear();
    _photoInProgress = false;
    _photoOrientation = null;
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
  }

  void dispose() {
    _cleanup();
    _stateController.close();
    _opusFrameController.close();
    _batteryController.close();
    _photoDataController.close();
  }
}
