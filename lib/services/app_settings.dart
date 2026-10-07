import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret app settings. Listen to it at the root (MaterialApp) so theme and
/// font size apply live; pass the inference values into ChatScreen.
class AppSettings extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  double fontScale = 1.0; // 0.85 .. 1.4
  String systemPrompt = 'You are a helpful coding assistant.';
  // Inference parameters are no longer user-configurable: the gateways pick
  // sensible defaults (null = omit from the request).
  static const double? temperature = null;
  static const double? topP = null;
  static const int? maxTokens = null;
  static const int contextMessages = 30; // recent messages sent as context
  String? workspaceUri; // SAF tree URI
  bool toolsEnabled = false; // let the model use repo tools (agent mode)

  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    themeMode = ThemeMode.values.firstWhere(
        (m) => m.name == _p.getString('theme'),
        orElse: () => ThemeMode.system);
    fontScale = _p.getDouble('fontScale') ?? 1.0;
    systemPrompt = _p.getString('systemPrompt') ?? systemPrompt;
    workspaceUri = _p.getString('workspaceUri');
    toolsEnabled = _p.getBool('toolsEnabled') ?? false;
    notifyListeners();
  }

  void _done() => notifyListeners();

  void setTheme(ThemeMode m) { themeMode = m; _p.setString('theme', m.name); _done(); }
  void setFontScale(double v) { fontScale = v; _p.setDouble('fontScale', v); _done(); }
  void setSystemPrompt(String v) { systemPrompt = v; _p.setString('systemPrompt', v); _done(); }
  void setToolsEnabled(bool v) { toolsEnabled = v; _p.setBool('toolsEnabled', v); _done(); }
  void setWorkspace(String? uri) {
    workspaceUri = uri;
    uri == null ? _p.remove('workspaceUri') : _p.setString('workspaceUri', uri);
    _done();
  }
}
