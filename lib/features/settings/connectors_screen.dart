import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/theme.dart';
import '../../services/app_settings.dart';
import '../../services/local_file_service.dart';

/// Where external services are connected: GitHub and a local workspace folder.
class ConnectorsScreen extends StatefulWidget {
  final AppSettings settings;
  final LocalFileService files;
  final bool githubConnected;
  final String? repoLabel;
  final VoidCallback onOpenGitHub;
  const ConnectorsScreen({
    super.key,
    required this.settings,
    required this.files,
    required this.githubConnected,
    required this.repoLabel,
    required this.onOpenGitHub,
  });

  @override
  State<ConnectorsScreen> createState() => _ConnectorsScreenState();
}

class _ConnectorsScreenState extends State<ConnectorsScreen> {
  AppSettings get s => widget.settings;

  Future<void> _pickWorkspace() async {
    final dir = await widget.files.pickWorkspace();
    if (dir != null) {
      s.setWorkspace(dir.uri.toString());
      Haptics.toggle();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sub = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: cs.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Connectors')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('GitHub', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
                widget.githubConnected
                    ? (widget.repoLabel ?? 'Connected. Choose a repository.')
                    : 'Not connected',
                style: sub),
            const SizedBox(height: 10),
            FilledButton.tonal(
                onPressed: widget.onOpenGitHub,
                child: Text(widget.githubConnected ? 'Change repo' : 'Connect & choose repo')),
          ]),
        ),
        const SizedBox(height: 12),
        Glass(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Workspace folder', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
                s.workspaceUri == null
                    ? 'No folder selected. Grant one folder; the app can only touch files inside it.'
                    : Uri.decodeFull(s.workspaceUri!),
                style: sub),
            const SizedBox(height: 10),
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
        ),
      ]),
    );
  }
}
