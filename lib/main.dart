import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'core/models.dart';
import 'core/theme.dart';
import 'features/chat/chat_screen.dart';
import 'features/github/github_screen.dart';
import 'features/providers/providers_screen.dart';
import 'features/proxy/proxy_screen.dart';
import 'features/settings/connectors_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/settings/skills_screen.dart';
import 'services/agent/agent_runner.dart';
import 'services/agent/agent_tools.dart';
import 'services/app_settings.dart';
import 'services/build_poller.dart';
import 'services/chat_codec.dart';
import 'services/default_providers.dart';
import 'services/github_service.dart';
import 'services/local_file_service.dart';
import 'services/openai_compatible_client.dart';
import 'services/proxy_controller.dart';
import 'services/proxy_server.dart';
import 'services/router_service.dart';
import 'services/secure_store.dart';
import 'services/session_store.dart';
import 'services/skill_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ProxyController.initForegroundService();
  final app = await AppServices.create();
  runApp(HubApp(app));
}

/// Manual service locator: one place that wires everything together.
class AppServices {
  // TODO: point at a providers.json you control (raw GitHub URL). Until then the
  // bundled assets/providers.json is used (network failure falls back silently).
  static const registryUrl =
      'https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/providers.json';

  final store = SecureStore();
  final client = OpenAICompatibleClient();
  final settings = AppSettings();
  final files = LocalFileService();
  final sessions = SessionStore();
  final skills = SkillStore();

  late final RouterService router;
  late final ProxyServer proxyServer;
  late final ProxyController proxy;

  List<ProviderDef> providers = [];
  List<Endpoint> chain = [];
  GitHubService? gh;
  BuildPoller? poller;
  RepoSelection? selection;

  // Agent workspace (staged changes) survives chat switches, and is reset when
  // the token or repo selection changes.
  AgentWorkspace? _ws;
  String? _wsKey;
  GitHubService? _wsGh;

  /// Null when GitHub isn't connected or no repo is chosen.
  AgentRunner? makeAgent() {
    final g = gh, sel = selection;
    if (g == null || sel == null) return null;
    final key = sel.encode();
    if (_ws == null || _wsKey != key || !identical(_wsGh, g)) {
      _ws = AgentWorkspace(g, sel.repo, sel.branch, sel.workflowFile);
      _wsKey = key;
      _wsGh = g;
    }
    return AgentRunner(router: router, toolkit: AgentToolkit(_ws!));
  }

  static Future<AppServices> create() async {
    final a = AppServices();
    await a.settings.load();
    await a.skills.load();
    a.providers = await ProviderRegistry(registryUrl).load();
    a.router = RouterService(client: a.client, chain: () => a.chain);
    a.proxyServer =
        ProxyServer(router: a.router, modelIds: () => [for (final e in a.chain) e.id]);
    a.proxy = ProxyController(a.proxyServer, a.store);
    await a.rebuildChain();
    unawaited(a.refreshGatewayModels()); // live model list, never blocks startup

    // Restore GitHub session if we have a token + repo.
    final token = await a.store.githubToken();
    if (token != null && token.isNotEmpty) {
      a.gh = GitHubService(token);
      a.poller = BuildPoller(a.gh!);
      a.selection = RepoSelection.decode(await a.store.repoSelection());
    }
    return a;
  }

  // Models the built-in gateways reported via GET /models (id -> models).
  final Map<String, List<String>> _discovered = {};
  DateTime? _lastRefresh;

  /// Ask OmniRoute / FreeLLMAPI what they serve right now. Throttled, short
  /// timeout, and failures are silent: the always-present "auto" targets keep
  /// working even when the listing endpoint is down.
  Future<void> refreshGatewayModels({bool force = false}) async {
    final last = _lastRefresh;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _lastRefresh = DateTime.now();
    await Future.wait([
      for (final g in DefaultProviders.all)
        () async {
          try {
            final ep = Endpoint(
                providerId: g.id, baseUrl: g.baseUrl, apiKey: g.apiKey, model: 'auto');
            final ids = await client.listModels(ep).timeout(const Duration(seconds: 5));
            _discovered[g.id] = ids.where((m) => m != 'auto').take(40).toList();
          } catch (_) {
            _discovered.remove(g.id); // unreachable: don't offer stale models
          }
        }(),
    ]);
    await rebuildChain();
  }

  /// Ordered fallback chain:
  ///  1. OmniRoute "auto"  2. FreeLLMAPI "auto"  (built in, zero setup)
  ///  3. any extra provider the user added a key for (optional)
  /// Models the gateways report are appended as pick-only entries, so the model
  /// switcher can pin one without lengthening the automatic fallback chain.
  Future<void> rebuildChain() async {
    final out = <Endpoint>[
      for (final g in DefaultProviders.all)
        Endpoint(providerId: g.id, baseUrl: g.baseUrl, apiKey: g.apiKey, model: 'auto'),
    ];
    final ordered = [
      ...providers.where((p) => p.id != 'custom'),
      ...providers.where((p) => p.id == 'custom'),
    ];
    for (final p in ordered) {
      if (DefaultProviders.isDefault(p.id)) continue;
      final isCustom = p.id == 'custom';
      final key = await store.apiKey(p.id) ?? '';
      final base = isCustom ? (await store.baseUrl(p.id) ?? p.baseUrl) : p.baseUrl;
      if (base.isEmpty) continue;
      if (p.requiresKey && key.isEmpty) continue;
      if (isCustom && key.isEmpty && (await store.baseUrl(p.id)) == null) continue;
      final models = isCustom ? ['auto'] : p.models;
      for (final m in models) {
        out.add(Endpoint(providerId: p.id, baseUrl: base, apiKey: key, model: m));
      }
    }
    for (final g in DefaultProviders.all) {
      for (final m in _discovered[g.id] ?? const <String>[]) {
        out.add(Endpoint(
            providerId: g.id,
            baseUrl: g.baseUrl,
            apiKey: g.apiKey,
            model: m,
            selectableOnly: true));
      }
    }
    chain = out;
  }
}

class HubApp extends StatelessWidget {
  final AppServices app;
  const HubApp(this.app, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app.settings,
        builder: (_, __) => MaterialApp(
          title: 'AI Dev Hub',
          debugShowCheckedModeBanner: false,
          themeMode: app.settings.themeMode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(app.settings.fontScale)),
            child: child!,
          ),
          home: HomeShell(app),
        ),
      );
}

class HomeShell extends StatefulWidget {
  final AppServices app;
  const HomeShell(this.app, {super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  AppServices get app => widget.app;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  List<ChatSession> _sessions = [];
  int _current = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    () async {
      _sessions = await app.sessions.load();
      if (_sessions.isEmpty) _sessions = [_newSession()];
      _current = _sessions.length - 1;
      if (mounted) setState(() => _ready = true);
    }();
  }

  ChatSession _newSession() => ChatSession('New chat', DateTime.now(), []);

  Future<void> _persist() => app.sessions.save(_sessions);

  void _onMessages(List<ChatMsg> msgs) {
    if (msgs.isEmpty) return;
    final old = _sessions[_current];
    final first = msgs.firstWhere((m) => m.role == 'user', orElse: () => msgs.first).text;
    final title = first.replaceAll('\n', ' ').trim();
    _sessions[_current] = ChatSession(
        title.length > 40 ? '${title.substring(0, 40)}…' : title, old.created, msgs);
    _persist();
  }

  void _newChat() {
    if (_sessions[_current].messages.isEmpty) return;
    setState(() {
      _sessions.add(_newSession());
      _current = _sessions.length - 1;
    });
    _persist();
  }

  void _deleteChat(int i) {
    setState(() {
      _sessions.removeAt(i);
      if (_sessions.isEmpty) _sessions.add(_newSession());
      _current = _current.clamp(0, _sessions.length - 1);
      if (i < _current) _current--;
    });
    _persist();
  }

  void _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  /// Drawer entries close the drawer first, then navigate.
  void _go(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  void _openSkills() => _push(SkillsScreen(store: app.skills));

  void _openConnectors() => _push(ConnectorsScreen(
        settings: app.settings,
        files: app.files,
        githubConnected: app.gh != null,
        repoLabel: app.selection == null ? null : app.selection!.repo,
        onOpenGitHub: _openGitHub,
      ));

  void _openProviders() => _push(ProvidersScreen(
        providers: app.providers,
        store: app.store,
        client: app.client,
        stats: () => app.router.stats,
      ));

  void _openProxy() => _push(ProxyScreen(controller: app.proxy));

  void _openSettings() => _push(SettingsScreen(
        settings: app.settings,
        loadSessions: () async => _sessions,
        importSessions: (list) async {
          setState(() => _sessions.addAll(list));
          await _persist();
        },
        onOpenProviders: _openProviders,
        onOpenProxy: _openProxy,
      ));

  Widget _drawer() {
    final cs = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text('AI Dev Hub', style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.tonalIcon(
              onPressed: () => _go(_newChat),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New chat'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('Chats',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: [
              for (var i = _sessions.length - 1; i >= 0; i--)
                ListTile(
                  dense: true,
                  selected: i == _current,
                  selectedTileColor: cs.primary.withOpacity(0.14),
                  title: Text(_sessions[i].title, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    tooltip: 'Delete chat',
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    onPressed: () {
                      Navigator.of(context).pop();
                      _deleteChat(i);
                    },
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    setState(() => _current = i);
                  },
                ),
            ]),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Skills'),
            onTap: () => _go(_openSkills),
          ),
          ListTile(
            leading: const Icon(Icons.extension_outlined),
            title: const Text('Connectors'),
            onTap: () => _go(_openConnectors),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings'),
            onTap: () => _go(_openSettings),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  // ---- builds -------------------------------------------------------------

  Stream<BuildStatus>? _triggerBuild() {
    final sel = app.selection, poller = app.poller;
    if (sel == null || poller == null) return null;
    return poller.run(sel.repo,
        workflowFile: sel.workflowFile,
        ref: sel.branch,
        correlationId: BuildPoller.newCorrelationId());
  }

  /// Download the artifact ZIP, unpack it, then install the APK or share the file.
  Future<void> _downloadArtifact(BuildArtifact a) async {
    try {
      final zip = await app.poller!.downloadArtifactZip(a);
      final archive = ZipDecoder().decodeBytes(zip);
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/builds');
      await dir.create(recursive: true);
      File? apk, other;
      for (final f in archive) {
        if (!f.isFile) continue;
        final name = f.name.split('/').last;
        final out = File('${dir.path}/$name');
        await out.writeAsBytes(f.content as List<int>);
        name.endsWith('.apk') ? apk = out : other = out;
      }
      if (apk != null) {
        await OpenFilex.open(apk.path, type: 'application/vnd.android.package-archive');
      } else if (other != null) {
        await Share.shareXFiles([XFile(other.path)]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    }
  }

  // ---- attach -------------------------------------------------------------

  Future<String?> _attachFile() async {
    try {
      final r = await FilePicker.platform.pickFiles();
      final path = r?.files.single.path;
      if (path == null) return null;
      final f = File(path);
      if (await f.length() > 200 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('File too large (limit 200 KB)')));
        }
        return null;
      }
      final text = await f.readAsString();
      final name = path.split('/').last;
      final ext = name.contains('.') ? name.split('.').last : '';
      return '```$ext path=$name\n$text\n```';
    } catch (_) {
      return null; // binary / unreadable
    }
  }

  Future<Attachment?> _attachPhoto() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.image);
      final path = r?.files.single.path;
      if (path == null) return null;
      final f = File(path);
      if (await f.length() > 4 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Photo too large (limit 4 MB)')));
        }
        return null;
      }
      final name = path.split('/').last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpeg';
      final mime = switch (ext) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      return Attachment(name, 'data:$mime;base64,${base64Encode(await f.readAsBytes())}');
    } catch (_) {
      return null;
    }
  }

  void _openGitHub() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GitHubScreen(
          store: app.store,
          onChanged: (gh, sel) {
            app.gh = gh;
            app.poller = BuildPoller(gh);
            app.selection = sel;
            if (mounted) setState(() {});
          },
        ),
      ));

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final s = app.settings;
    final session = _sessions[_current];

    return Scaffold(
      key: _scaffoldKey,
      drawer: _drawer(),
      body: ListenableBuilder(
        listenable: app.skills,
        builder: (_, __) => ChatScreen(
          key: ValueKey(session.created.toIso8601String()),
          router: app.router,
          models: app.router.available,
          onModelMenuOpen: () =>
              app.refreshGatewayModels().then((_) => mounted ? setState(() {}) : null),
          systemPrompt: s.systemPrompt,
          skills: app.skills,
          onManageSkills: _openSkills,
          contextMessages: AppSettings.contextMessages,
          initial: session.messages,
          onMessagesChanged: _onMessages,
          onOpenMenu: () => _scaffoldKey.currentState?.openDrawer(),
          onNewChat: _newChat,
          onOpenGitHub: _openGitHub,
          githubConnected: app.gh != null,
          onTriggerBuild: _triggerBuild,
          onDownloadArtifact: _downloadArtifact,
          onPickFile: _attachFile,
          onPickPhoto: _attachPhoto,
          toolsEnabled: s.toolsEnabled,
          agentFactory: app.makeAgent,
        ),
      ),
    );
  }
}
