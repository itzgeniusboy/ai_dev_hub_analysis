import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/app_settings.dart';
import '../../services/chat_codec.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final Future<List<ChatSession>> Function() loadSessions;
  final Future<void> Function(List<ChatSession>) importSessions;
  final VoidCallback? onOpenProviders;
  final VoidCallback? onOpenProxy;
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.loadSessions,
    required this.importSessions,
    this.onOpenProviders,
    this.onOpenProxy,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get s => widget.settings;
  late final _prompt = TextEditingController(text: s.systemPrompt);

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _export(bool markdown) async {
    try {
      final sessions = await widget.loadSessions();
      if (sessions.isEmpty) return _toast('No chats to export');
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/chats.${markdown ? 'md' : 'json'}');
      await f.writeAsString(
          markdown ? ChatCodec.toMarkdown(sessions) : ChatCodec.toJson(sessions));
      Haptics.toggle();
      await Share.shareXFiles([XFile(f.path)]);
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  Future<void> _import() async {
    try {
      final r = await FilePicker.platform
          .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      final path = r?.files.single.path;
      if (path == null) return;
      final sessions = ChatCodec.fromJson(await File(path).readAsString());
      await widget.importSessions(sessions);
      Haptics.copy();
      _toast('Imported ${sessions.length} chat(s)');
    } on FormatException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Import failed: $e');
    }
  }

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        _section('Appearance', [
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) {
              Haptics.toggle();
              s.setTheme(v.first);
              setState(() {});
            },
          ),
          const SizedBox(height: 8),
          _FontSizeSlider(value: s.fontScale, onEnd: s.setFontScale),
        ]),
        _section('Assistant', [
          TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Default system prompt'),
            onChanged: s.setSystemPrompt,
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Let the model work on my repo'),
            subtitle: const Text(
                'Read and stage files on the selected GitHub repo. Commits and builds always ask first. Needs a model with tool calling.'),
            value: s.toolsEnabled,
            onChanged: (v) {
              Haptics.toggle();
              s.setToolsEnabled(v);
              setState(() {});
            },
          ),
        ]),
        _section('Chats', [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonal(onPressed: () => _export(false), child: const Text('Export JSON')),
            FilledButton.tonal(onPressed: () => _export(true), child: const Text('Export Markdown')),
            FilledButton.tonal(onPressed: _import, child: const Text('Import JSON')),
          ]),
        ]),
        _section('Advanced', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.hub_outlined),
            title: const Text('Extra providers'),
            subtitle: const Text('Optional. OmniRoute and FreeLLMAPI are built in.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: widget.onOpenProviders,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Local proxy server'),
            subtitle: const Text('Share the router with other apps on this device.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: widget.onOpenProxy,
          ),
        ]),
      ]),
    );
  }
}

/// Font-size slider: shows the value live while dragging, persists on release.
class _FontSizeSlider extends StatefulWidget {
  final double value;
  final ValueChanged<double> onEnd;
  const _FontSizeSlider({required this.value, required this.onEnd});

  @override
  State<_FontSizeSlider> createState() => _FontSizeSliderState();
}

class _FontSizeSliderState extends State<_FontSizeSlider> {
  late double _v = widget.value;

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          const Expanded(child: Text('Font size')),
          Text(_v.toStringAsFixed(2)),
        ]),
        Slider(
          value: _v,
          min: 0.85,
          max: 1.4,
          divisions: 11,
          onChanged: (x) => setState(() => _v = x),
          onChangeEnd: widget.onEnd,
        ),
      ]);
}
