import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime configuration for the ADK agent connection, read from the `.env`
/// file (bundled as an asset, loaded in `main()`).
///
/// Set `ADK_WS_URL` to the full WebSocket URL of your ADK bidi-streaming agent.
/// The app appends `?is_audio=<bool>` automatically. The default targets a local
/// ADK server (`10.0.2.2` is the host's localhost as seen from the Android
/// emulator; use your machine's LAN IP for a physical device).
class AppConfig {
  static const String _defaultWsUrl = 'ws://10.0.2.2:8000/ws/chopper-user';

  static String get wsUrl {
    final value = (dotenv.maybeGet('ADK_WS_URL') ?? '').trim();
    return value.isEmpty ? _defaultWsUrl : value;
  }

  /// Matches the ADK bidi sample route: `/ws/{user_id}?is_audio=<bool>`.
  static Uri wsUri({required bool isAudio}) {
    final base = Uri.parse(wsUrl);
    final query = <String, String>{...base.queryParameters, 'is_audio': '$isAudio'};
    return base.replace(queryParameters: query);
  }
}

