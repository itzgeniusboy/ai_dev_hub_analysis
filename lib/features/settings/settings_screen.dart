import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/app_settings.dart';
import '../../services/chat_codec.dart';
import '../../services/local_file_service.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  final LocalFileService files;
  final Future<List<ChatSession>> Function() loadSessions;
  final Future<void> Function(List<ChatSession>) importSessions;
  final VoidCallback? onOpenGitHub;
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.files,
    required this.loadSessions,
    required this.importSessions,
    this.onOpenGitHub,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get s => widget.settings;
  late final _prompt = TextEditingController(text: s.systemPrompt);
  late final _maxTok = TextEditingController(text: '${s.maxTokens}');

  @override
  void dispose() {
    _prompt.dispose();
    _maxTok.dispose();
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

  Future<void> _pickWorkspace() async {
    final dir = await widget.files.pickWorkspace();
    if (dir != null) {
      s.setWorkspace(dir.uri.toString());
      Haptics.toggle();
      setState(() {});
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

  Widget _slider(String label, double v, double min, double max, int div,
          ValueChanged<double> onEnd, {int digits = 2}) =>
      _LiveSlider(
          label: label, value: v, min: min, max: max, divisions: div,
          digits: digits, onEnd: onEnd);

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
          _slider('Font size', s.fontScale, 0.85, 1.4, 11, s.setFontScale),
        ]),
        _section('Inference', [
          TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Default system prompt'),
            onChanged: s.setSystemPrompt,
          ),
          const SizedBox(height: 8),
          _slider('Temperature', s.temperature, 0, 2, 20, s.setTemperature),
          _slider('Top-P', s.topP, 0.05, 1, 19, s.setTopP),
          TextField(
            controller: _maxTok,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Max tokens'),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n > 0) s.setMaxTokens(n);
            },
          ),
          _slider('Context (recent messages sent)', s.contextMessages.toDouble(), 2, 100,
              98, (v) => s.setContextMessages(v.round()), digits: 0),
        ]),
        _section('GitHub', [
          FilledButton.tonal(
              onPressed: widget.onOpenGitHub, child: const Text('Connect & choose repo')),
        ]),
        _section('Agent tools', [
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
        _section('Workspace', [
          Text(s.workspaceUri == null
              ? 'No folder selected. Grant one folder; the app can only touch files inside it.'
              : Uri.decodeFull(s.workspaceUri!),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            FilledButton.tonal(
                onPressed: _pickWorkspace,
                child: Text(s.workspaceUri == null ? 'Choose folder' : 'Change folder')),
            if (s.workspaceUri != null)
              TextButton(
                  onPressed: () {
                    s.setWorkspace(null);
                    setState(() {});
                  },
                  child: const Text('Forget')),
          ]),
        ]),
        _section('Chats', [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonal(onPressed: () => _export(false), child: const Text('Export JSON')),
            FilledButton.tonal(onPressed: () => _export(true), child: const Text('Export Markdown')),
            FilledButton.tonal(onPressed: _import, child: const Text('Import JSON')),
          ]),
        ]),
      ]),
    );
  }
}

/// Slider that shows the value live while dragging and persists on release.
class _LiveSlider extends StatefulWidget {
  final String label;
  final double value, min, max;
  final int divisions, digits;
  final ValueChanged<double> onEnd;
  const _LiveSlider({required this.label, required this.value, required this.min,
      required this.max, required this.divisions, required this.digits, required this.onEnd});

  @override
  State<_LiveSlider> createState() => _LiveSliderState();
}

class _LiveSliderState extends State<_LiveSlider> {
  late double _v = widget.value;

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          Expanded(child: Text(widget.label)),
          Text(_v.toStringAsFixed(widget.digits)),
        ]),
        Slider(
          value: _v,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: (x) => setState(() => _v = x),
          onChangeEnd: widget.onEnd,
        ),
      ]);
}
