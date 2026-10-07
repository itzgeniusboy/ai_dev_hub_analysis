import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RouteMode { direct, gateway }

/// Secrets live in EncryptedSharedPreferences (Android Keystore-backed) /
/// Keychain (iOS). Non-secret settings use plain SharedPreferences.
class SecureStore {
  final _s = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));

  Future<String?> apiKey(String providerId) => _s.read(key: 'key:$providerId');
  Future<void> setApiKey(String providerId, String? v) => (v == null || v.isEmpty)
      ? _s.delete(key: 'key:$providerId')
      : _s.write(key: 'key:$providerId', value: v);

  Future<String?> githubToken() => _s.read(key: 'github_pat');
  Future<void> setGithubToken(String? v) => (v == null || v.isEmpty)
      ? _s.delete(key: 'github_pat')
      : _s.write(key: 'github_pat', value: v);

  Future<String?> proxyToken() => _s.read(key: 'proxy_token');
  Future<void> setProxyToken(String v) => _s.write(key: 'proxy_token', value: v);

  // ---- non-secret ----
  Future<String?> baseUrl(String providerId) async =>
      (await SharedPreferences.getInstance()).getString('base:$providerId');
  Future<void> setBaseUrl(String providerId, String v) async =>
      (await SharedPreferences.getInstance()).setString('base:$providerId', v);

  Future<RouteMode> mode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('route_mode') == 'gateway' ? RouteMode.gateway : RouteMode.direct;
  }

  Future<void> setMode(RouteMode m) async =>
      (await SharedPreferences.getInstance()).setString('route_mode', m.name);

  /// "owner/repo|branch|workflowFile"
  Future<String?> repoSelection() async =>
      (await SharedPreferences.getInstance()).getString('repo_sel');
  Future<void> setRepoSelection(String v) async =>
      (await SharedPreferences.getInstance()).setString('repo_sel', v);
}
