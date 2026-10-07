import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret app settings. Listen to it at the root (MaterialApp) so theme and
/// font size apply live; pass the inference values into ChatScreen.
class AppSettings extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.system;
  double fontScale = 1.0; // 0.85 .. 1.4
  String systemPrompt = 'You are a helpful coding assistant.';
  double temperature = 0.7;
  double topP = 1.0;
  int maxTokens = 4096;
  int contextMessages = 20; // how many recent messages to send (context window)
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
    temperature = _p.getDouble('temperature') ?? 0.7;
    topP = _p.getDouble('topP') ?? 1.0;
    maxTokens = _p.getInt('maxTokens') ?? 4096;
    contextMessages = _p.getInt('contextMessages') ?? 20;
    workspaceUri = _p.getString('workspaceUri');
    toolsEnabled = _p.getBool('toolsEnabled') ?? false;
    notifyListeners();
  }

  void _done() => notifyListeners();

  void setTheme(ThemeMode m) { themeMode = m; _p.setString('theme', m.name); _done(); }
  void setFontScale(double v) { fontScale = v; _p.setDouble('fontScale', v); _done(); }
  void setSystemPrompt(String v) { systemPrompt = v; _p.setString('systemPrompt', v); _done(); }
  void setTemperature(double v) { temperature = v; _p.setDouble('temperature', v); _done(); }
  void setTopP(double v) { topP = v; _p.setDouble('topP', v); _done(); }
  void setMaxTokens(int v) { maxTokens = v; _p.setInt('maxTokens', v); _done(); }
  void setContextMessages(int v) { contextMessages = v; _p.setInt('contextMessages', v); _done(); }
  void setToolsEnabled(bool v) { toolsEnabled = v; _p.setBool('toolsEnabled', v); _done(); }
  void setWorkspace(String? uri) {
    workspaceUri = uri;
    uri == null ? _p.remove('workspaceUri') : _p.setString('workspaceUri', uri);
    _done();
  }
}
