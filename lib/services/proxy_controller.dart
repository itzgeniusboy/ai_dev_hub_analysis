import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'proxy_server.dart';
import 'secure_store.dart';

/// Owns ProxyServer + the Android foreground service that keeps the process
/// (and therefore the server isolate) alive when the app is backgrounded.
/// The server runs in the main isolate, so the service is only a keep-alive.
class ProxyController {
  final ProxyServer server;
  final SecureStore store;
  ProxyController(this.server, this.store);

  int port = 8080;
  bool lan = false;

  static void initForegroundService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ai_hub_proxy',
        channelName: 'Local AI proxy',
        channelDescription: 'Keeps the local OpenAI-compatible server running.',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true, // keep Wi-Fi awake so LAN clients stay connected
      ),
    );
  }

  Future<void> loadToken() async {
    final saved = await store.proxyToken();
    if (saved != null && saved.isNotEmpty) {
      server.bearerToken = saved;
    } else {
      await store.setProxyToken(server.bearerToken);
    }
  }

  Future<void> start() async {
    // Android 13+: notification permission is needed for the service notice.
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    await server.start(port: port, lan: lan);
    await FlutterForegroundTask.startService(
      notificationTitle: 'AI proxy running',
      notificationText: lan ? 'Listening on Wi-Fi :$port' : 'Listening on localhost :$port',
    );
  }

  Future<void> stop() async {
    await server.stop();
    await FlutterForegroundTask.stopService();
  }

  Future<String> regenerateToken() async {
    final t = ProxyServer.generateToken();
    server.bearerToken = t; // takes effect immediately, no restart
    await store.setProxyToken(t);
    return t;
  }
}
