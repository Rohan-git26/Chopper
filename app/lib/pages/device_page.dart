import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../providers/chat_provider.dart';
import '../services/omi_device_service.dart';

class DevicePage extends StatefulWidget {
  const DevicePage({super.key});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  final List<fbp.BluetoothDevice> _devices = [];
  bool _isScanning = false;

  ChatProvider get _provider => Provider.of<ChatProvider>(context, listen: false);

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

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final scanning = provider.deviceState == DeviceConnectionState.scanning || _isScanning;
        return WillPopScope(
          onWillPop: _onWillPop,
          child: Scaffold(
            backgroundColor: const Color(0xFF0E0E12),
            appBar: AppBar(
              backgroundColor: const Color(0xFF15151B),
              elevation: 0,
              title: const Text('Devices'),
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
                                if (provider.deviceConnected && context.mounted) {
                                  provider.stopDeviceScan();
                                  provider.onDeviceDiscovered = null;
                                  Navigator.of(context).pop();
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
