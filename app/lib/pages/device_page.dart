import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../providers/chat_provider.dart';
import '../services/omi_device_service.dart';
import 'log_page.dart';
import 'video_page.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({super.key});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final List<fbp.BluetoothDevice> _devices = [];
  bool _isScanning = false;

  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _wifiFieldsSeeded = false;
  bool _obscurePassword = true;

  // Cache the provider so dispose() doesn't do a context lookup (illegal once
  // the widget is deactivated — it throws "deactivated widget's ancestor").
  late final ChatProvider _provider =
      Provider.of<ChatProvider>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _provider.onDeviceDiscovered = (dev) {
      if (!_devices.any((d) => d.remoteId == dev.remoteId)) {
        setState(() => _devices.add(dev));
      }
    };
  }

  @override
  void dispose() {
    _provider.stopDeviceScan();
    _provider.onDeviceDiscovered = null;
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<bool> _onWillPop() async {
    _provider.stopDeviceScan();
    _provider.onDeviceDiscovered = null;
    return true;
  }

  Future<void> _toggleScan() async {
    final scanning = _provider.deviceState == DeviceConnectionState.scanning || _isScanning;
    if (scanning) {
      _provider.stopDeviceScan();
      setState(() {
        _isScanning = false;
      });
    } else {
      _devices.clear();
      setState(() {
        _isScanning = true;
      });
      _provider.onDeviceDiscovered = (dev) {
        if (!_devices.any((d) => d.remoteId == dev.remoteId)) {
          setState(() => _devices.add(dev));
        }
      };
      await _provider.startDeviceScan();
    }
  }

  // ---- Photo transport (BLE / WiFi) ----------------------------------------

  Widget _buildPhotoTransportCard(BuildContext context, ChatProvider provider) {
    final isWifi = provider.photoTransport == PhotoTransport.wifi;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Photo transport',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Row(
            children: [
              _transportChip(provider, PhotoTransport.ble, 'BLE'),
              const SizedBox(width: 8),
              _transportChip(provider, PhotoTransport.wifi, 'WiFi'),
            ],
          ),
          if (isWifi) ...[
            const SizedBox(height: 16),
            _wifiSection(context, provider),
          ],
        ],
      ),
    );
  }

  Widget _transportChip(ChatProvider provider, PhotoTransport t, String label) {
    final selected = provider.photoTransport == t;
    return Expanded(
      child: GestureDetector(
        onTap: () => provider.setPhotoTransport(t),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? Colors.white : const Color(0xFF2A2A30),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _wifiSection(BuildContext context, ChatProvider provider) {
    final status = provider.wifiPhotoStatus;
    final connected = status == WifiPhotoStatus.connected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ssidController,
          style: const TextStyle(color: Colors.white),
          decoration: _wifiInputDecoration('WiFi name (SSID)'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passwordController,
          obscureText: _obscurePassword,
          style: const TextStyle(color: Colors.white),
          decoration: _wifiInputDecoration('WiFi password').copyWith(
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility : Icons.visibility_off,
                color: Colors.grey,
                size: 20,
              ),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(_wifiStatusIcon(status), size: 16, color: _wifiStatusColor(status)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _wifiStatusText(provider),
                style: TextStyle(color: _wifiStatusColor(status), fontSize: 13),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Phone and glasses must be on the same WiFi network.',
          style: TextStyle(color: Colors.grey, fontSize: 11),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: connected
              ? OutlinedButton.icon(
                  onPressed: () => provider.disableWifi(),
                  icon: const Icon(Icons.wifi_off),
                  label: const Text('Disconnect WiFi'),
                )
              : ElevatedButton.icon(
                  onPressed: status == WifiPhotoStatus.connecting
                      ? null
                      : () => _connectWifi(context, provider),
                  icon: const Icon(Icons.wifi),
                  label: Text(status == WifiPhotoStatus.connecting
                      ? 'Connecting…'
                      : 'Connect WiFi'),
                ),
        ),
        if (connected) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const VideoPage()),
              ),
              icon: const Icon(Icons.videocam),
              label: const Text('Live Video'),
            ),
          ),
        ],
      ],
    );
  }

  InputDecoration _wifiInputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey[600]),
        filled: true,
        fillColor: const Color(0xFF2A2A30),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      );

  String _wifiStatusText(ChatProvider p) {
    switch (p.wifiPhotoStatus) {
      case WifiPhotoStatus.connected:
        return 'Connected · ${p.wifiIp ?? ''}';
      case WifiPhotoStatus.connecting:
        return 'Connecting…';
      case WifiPhotoStatus.failed:
        return 'Connection failed';
      case WifiPhotoStatus.disconnected:
        return 'WiFi off';
    }
  }

  Color _wifiStatusColor(WifiPhotoStatus s) {
    switch (s) {
      case WifiPhotoStatus.connected:
        return const Color(0xFF29CC8F);
      case WifiPhotoStatus.connecting:
        return Colors.amber;
      case WifiPhotoStatus.failed:
        return Colors.redAccent;
      case WifiPhotoStatus.disconnected:
        return Colors.grey;
    }
  }

  IconData _wifiStatusIcon(WifiPhotoStatus s) {
    switch (s) {
      case WifiPhotoStatus.connected:
        return Icons.wifi;
      case WifiPhotoStatus.connecting:
        return Icons.wifi_find;
      case WifiPhotoStatus.failed:
      case WifiPhotoStatus.disconnected:
        return Icons.wifi_off;
    }
  }

  Future<void> _connectWifi(BuildContext context, ChatProvider provider) async {
    final ssid = _ssidController.text.trim();
    final pass = _passwordController.text;
    if (ssid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a WiFi name (SSID)')),
      );
      return;
    }
    try {
      await provider.enableWifi(ssid, pass);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('WiFi connect failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final scanning = provider.deviceState == DeviceConnectionState.scanning || _isScanning;
        // Seed the WiFi text fields once from persisted credentials.
        if (!_wifiFieldsSeeded && provider.wifiSsid.isNotEmpty) {
          _ssidController.text = provider.wifiSsid;
          _passwordController.text = provider.wifiPassword;
          _wifiFieldsSeeded = true;
        }
        return WillPopScope(
          onWillPop: _onWillPop,
          child: Scaffold(
            backgroundColor: const Color(0xFF0E0E12),
            appBar: AppBar(
              backgroundColor: const Color(0xFF15151B),
              elevation: 0,
              title: const Text('Devices'),
              actions: [
                IconButton(
                  tooltip: 'Logs',
                  icon: const Icon(Icons.terminal),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LogPage()),
                  ),
                ),
              ],
            ),
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F25),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          provider.deviceConnected ? 'Connected' : 'Scan for Chopper glasses',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          provider.deviceStatusText,
                          style: TextStyle(color: Colors.grey[400], fontSize: 13),
                        ),
                        if (provider.deviceBattery != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Battery: ${provider.deviceBattery}%',
                            style: TextStyle(color: Colors.grey[400], fontSize: 13),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (provider.deviceConnected) ...[
                    const SizedBox(height: 12),
                    _buildPhotoTransportCard(context, provider),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _toggleScan,
                      icon: Icon(scanning ? Icons.stop : Icons.search),
                      label: Text(scanning ? 'Stop Scanning' : 'Scan for device'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_devices.isNotEmpty) ...[
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Found Devices', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _devices.length,
                        separatorBuilder: (_, __) => const Divider(color: Color(0xFF2A2A30)),
                        itemBuilder: (ctx, i) {
                          final dev = _devices[i];
                          return ListTile(
                            leading: const Icon(Icons.bluetooth, color: Colors.white),
                            title: Text(dev.platformName.isNotEmpty ? dev.platformName : 'Unknown', style: const TextStyle(color: Colors.white)),
                            subtitle: Text(dev.remoteId.str, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                            trailing: ElevatedButton(
                              onPressed: () async {
                                await provider.connectToDevice(dev);
                                if (!context.mounted) return;
                                if (provider.deviceConnected) {
                                  provider.stopDeviceScan();
                                  provider.onDeviceDiscovered = null;
                                  Navigator.of(context).pop();
                                } else if (provider.deviceError != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Connect failed: ${provider.deviceError}')),
                                  );
                                }
                              },
                              child: const Text('Connect'),
                            ),
                          );
                        },
                      ),
                    ),
                  ] else if (scanning) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 20),
                      child: Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.white))),
                    ),
                  ],
                  if (provider.deviceConnected)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await provider.disconnectDevice();
                        },
                        icon: const Icon(Icons.bluetooth_disabled),
                        label: const Text('Disconnect'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
