import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:opus_dart/opus_dart.dart';
import 'package:provider/provider.dart';

import 'pages/auth_page.dart';
import 'pages/home_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'services/foreground_task_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'chopper_foreground_service',
      channelName: 'Chopper foreground service',
      channelDescription:
          'Keeps BLE + audio streaming alive while the app runs in the background.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      allowWifiLock: true,
    ),
  );

  FlutterForegroundTask.setTaskHandler(ForegroundTaskHandler());

  try {
    initOpus(await opus_flutter.load());
  } catch (_) {
    // Opus initialization failure is not fatal — audio from the
    // chopper glasses simply won't decode. We'll surface this later
    // in the UI (Phase 1+).
  }

  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Firebase initialization is best-effort at startup so the app can still
    // boot in environments without full Firebase configuration.
  }

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    dotenv.testLoad(fileInput: '');
  }
  runApp(const ChopperApp());
}

class ChopperApp extends StatelessWidget {
  const ChopperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
      ],
      child: MaterialApp(
        title: 'Chopper',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF0E0E12),
        ),
        home: const AuthGate(),
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    return authProvider.isAuthenticated ? const HomePage() : const AuthPage();
  }
}

