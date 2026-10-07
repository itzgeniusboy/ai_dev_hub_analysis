import 'package:flutter/services.dart';

class TerminalStatus {
  final bool shizukuInstalled, shizukuRunning, shizukuGranted, termuxInstalled, termuxPermission;
  const TerminalStatus({
    this.shizukuInstalled = false,
    this.shizukuRunning = false,
    this.shizukuGranted = false,
    this.termuxInstalled = false,
    this.termuxPermission = false,
  });
  bool get termuxReady => termuxInstalled && termuxPermission;
  bool get shizukuReady => shizukuRunning && shizukuGranted;
}

class CmdResult {
  final String stdout, stderr;
  final int? exitCode;
  final bool timedOut;
  final String? error;
  const CmdResult(this.stdout, this.stderr, this.exitCode, this.timedOut, this.error);
  bool get ok => error == null && !timedOut && exitCode == 0;

  factory CmdResult.fromMap(Map m) => CmdResult(
        (m['stdout'] ?? '') as String,
        (m['stderr'] ?? '') as String,
        m['exitCode'] as int?,
        m['timedOut'] == true,
        m['error'] as String?,
      );
  factory CmdResult.failure(String msg) => CmdResult('', '', null, false, msg);
}

/// Thin wrapper over the native channel in android_overlay/MainActivity.kt.
class TerminalBridge {
  static const _ch = MethodChannel('ai_dev_hub/terminal');

  Future<TerminalStatus> status() async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('status') ?? {};
      return TerminalStatus(
        shizukuInstalled: m['shizukuInstalled'] == true,
        shizukuRunning: m['shizukuRunning'] == true,
        shizukuGranted: m['shizukuGranted'] == true,
        termuxInstalled: m['termuxInstalled'] == true,
        termuxPermission: m['termuxPermission'] == true,
      );
    } catch (_) {
      return const TerminalStatus(); // not Android / channel missing
    }
  }

  Future<bool> requestShizuku() async => await _bool('shizukuRequest');
  Future<bool> requestTermuxPermission() async => await _bool('termuxRequestPermission');
  Future<bool> openTermux() async => await _bool('openTermux');

  /// Uses Shizuku (adb-shell identity) to grant this app the Termux RUN_COMMAND permission.
  Future<CmdResult> grantTermuxViaShizuku() => _run('grantTermuxViaShizuku', {});

  Future<CmdResult> shizukuShell(String command, {int timeoutMs = 60000}) =>
      _run('shizukuShell', {'command': command, 'timeoutMs': timeoutMs});

  Future<CmdResult> termux(String command, {String? workdir, int timeoutMs = 60000}) =>
      _run('termuxRun', {'command': command, 'workdir': workdir, 'timeoutMs': timeoutMs});

  Future<bool> _bool(String method) async {
    try {
      return (await _ch.invokeMethod<bool>(method)) == true;
    } catch (_) {
      return false;
    }
  }

  Future<CmdResult> _run(String method, Map<String, dynamic> args) async {
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>(method, args);
      return m == null ? CmdResult.failure('No response from native bridge.') : CmdResult.fromMap(m);
    } on MissingPluginException {
      return CmdResult.failure('Terminal bridge is Android-only (native overlay not built in).');
    } catch (e) {
      return CmdResult.failure('$e');
    }
  }
}
