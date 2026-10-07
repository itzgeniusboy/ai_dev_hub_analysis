import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/app_settings.dart';
import '../../services/terminal/terminal_bridge.dart';

class TerminalScreen extends StatefulWidget {
  final AppSettings settings;
  final TerminalBridge bridge;
  const TerminalScreen({super.key, required this.settings, required this.bridge});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  static const _propsCmd =
      'mkdir -p ~/.termux && grep -q "^allow-external-apps" ~/.termux/termux.properties 2>/dev/null || echo "allow-external-apps=true" >> ~/.termux/termux.properties';

  TerminalStatus _s = const TerminalStatus();
  String? _msg;
  bool _busy = false;
  AppSettings get st => widget.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await widget.bridge.status();
    if (mounted) setState(() => _s = s);
  }

  Future<void> _do(Future<String?> Function() f) async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final m = await f();
    await _refresh();
    if (mounted) setState(() {
      _busy = false;
      _msg = m;
    });
  }

  Widget _row(bool ok, String title, [String? sub, Widget? action]) => ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
            color: ok ? Colors.green : Theme.of(context).colorScheme.outline),
        title: Text(title),
        subtitle: sub == null ? null : Text(sub),
        trailing: action,
      );

  @override
  Widget build(BuildContext context) {
    final b = widget.bridge;
    return Scaffold(
      appBar: AppBar(title: const Text('Terminal (Termux + Shizuku)')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Glass(
          child: Column(children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Let the model run commands'),
              subtitle: const Text('Adds termux_run and shell_run tools to the chat agent.'),
              value: st.terminalEnabled,
              onChanged: (v) {
                Haptics.toggle();
                st.setTerminalEnabled(v);
                setState(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ask before every command'),
              subtitle: Text(st.terminalConfirm
                  ? 'You see and approve each command first (recommended).'
                  : 'Commands run immediately. A bad or injected instruction can change or delete data.'),
              value: st.terminalConfirm,
              onChanged: (v) {
                Haptics.toggle();
                st.setTerminalConfirm(v);
                setState(() {});
              },
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Termux', style: Theme.of(context).textTheme.titleSmall),
            _row(_s.termuxInstalled, '1. Termux installed', 'Use the F-Droid or GitHub build, not Google Play.'),
            _row(false, '2. Allow external apps',
                'Cannot be detected. Run this once inside Termux, then restart Termux:',
                IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () async {
                      await Clipboard.setData(const ClipboardData(text: _propsCmd));
                      Haptics.copy();
                    })),
            _row(_s.termuxPermission, '3. "Run commands in Termux" permission', null,
                _s.termuxPermission
                    ? null
                    : TextButton(
                        onPressed: _busy
                            ? null
                            : () => _do(() async {
                                  if (_s.shizukuReady) {
                                    final r = await b.grantTermuxViaShizuku();
                                    if (r.ok) return 'Granted via Shizuku.';
                                  }
                                  final ok = await b.requestTermuxPermission();
                                  return ok ? 'Granted.' : 'Not granted. Open App info > Permissions > Additional permissions.';
                                }),
                        child: const Text('Grant'))),
            Wrap(spacing: 8, children: [
              TextButton(onPressed: b.openTermux, child: const Text('Open Termux')),
              TextButton(
                  onPressed: _busy || !_s.termuxReady
                      ? null
                      : () => _do(() async {
                            final r = await b.termux('echo ok; uname -m', timeoutMs: 20000);
                            return r.ok ? 'Termux test passed:\n${r.stdout.trim()}' : 'Termux test failed: ${r.error ?? r.stderr}';
                          }),
                  child: const Text('Test')),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Shizuku (Android shell access)', style: Theme.of(context).textTheme.titleSmall),
            _row(_s.shizukuInstalled, 'Shizuku app installed'),
            _row(_s.shizukuRunning, 'Shizuku running', 'Start it from the Shizuku app (wireless debugging or adb).'),
            _row(_s.shizukuGranted, 'Permission for AI Dev Hub', null,
                _s.shizukuGranted
                    ? null
                    : TextButton(
                        onPressed: _busy || !_s.shizukuRunning
                            ? null
                            : () => _do(() async => (await b.requestShizuku()) ? 'Shizuku permission granted.' : 'Shizuku permission denied.'),
                        child: const Text('Request'))),
            TextButton(
                onPressed: _busy || !_s.shizukuReady
                    ? null
                    : () => _do(() async {
                          final r = await b.shizukuShell('id');
                          return r.ok ? 'Shell test passed:\n${r.stdout.trim()}' : 'Shell test failed: ${r.error ?? r.stderr}';
                        }),
                child: const Text('Test')),
          ]),
        ),
        if (_msg != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(_msg!)),
        const SizedBox(height: 12),
        const Text(
            'Shizuku cannot send commands into Termux by itself (the adb shell user is not allowed to). '
            'Termux commands go through Termux\'s RUN_COMMAND intent; Shizuku is used to auto-grant that permission '
            'and to run Android shell commands.',
            style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}
