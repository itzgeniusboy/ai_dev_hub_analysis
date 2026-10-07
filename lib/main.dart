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
import 'features/settings/settings_screen.dart';
import 'services/agent/agent_runner.dart';
import 'services/agent/agent_tools.dart';
import 'services/app_settings.dart';
import 'services/build_poller.dart';
import 'services/chat_codec.dart';
import 'services/github_service.dart';
import 'services/local_file_service.dart';
import 'services/openai_compatible_client.dart';
import 'services/proxy_controller.dart';
import 'services/proxy_server.dart';
import 'services/router_service.dart';
import 'services/secure_store.dart';
import 'services/session_store.dart';

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
    a.providers = await ProviderRegistry(registryUrl).load();
    a.router = RouterService(client: a.client, chain: () => a.chain);
    a.proxyServer =
        ProxyServer(router: a.router, modelIds: () => [for (final e in a.chain) e.id]);
    a.proxy = ProxyController(a.proxyServer, a.store);
    await a.rebuildChain();

    // Restore GitHub session if we have a token + repo.
    final token = await a.store.githubToken();
    if (token != null && token.isNotEmpty) {
      a.gh = GitHubService(token);
      a.poller = BuildPoller(a.gh!);
      a.selection = RepoSelection.decode(await a.store.repoSelection());
    }
    return a;
  }

  /// Resolve saved keys + mode into an ordered fallback chain.
  /// Gateway mode: only the Custom provider, model "auto" (the gateway routes).
  /// Direct mode: every provider that has a key (Custom last, if its URL is set).
  Future<void> rebuildChain() async {
    final mode = await store.mode();
    final out = <Endpoint>[];
    final ordered = [
      ...providers.where((p) => p.id != 'custom'),
      ...providers.where((p) => p.id == 'custom'),
    ];
    for (final p in ordered) {
      final isCustom = p.id == 'custom';
      if (mode == RouteMode.gateway && !isCustom) continue;
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
  int _tab = 0;
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

  void _openSessions() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('New chat'),
            onTap: () {
              Navigator.pop(ctx);
              if (_sessions[_current].messages.isNotEmpty) {
                setState(() {
                  _sessions.add(_newSession());
                  _current = _sessions.length - 1;
                });
                _persist();
              }
            },
          ),
          for (var i = _sessions.length - 1; i >= 0; i--)
            ListTile(
              selected: i == _current,
              title: Text(_sessions[i].title, overflow: TextOverflow.ellipsis),
              subtitle: Text('${_sessions[i].messages.length} messages'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _sessions.removeAt(i);
                    if (_sessions.isEmpty) _sessions.add(_newSession());
                    _current = _current.clamp(0, _sessions.length - 1);
                    if (i < _current) _current--;
                  });
                  _persist();
                },
              ),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _current = i);
              },
            ),
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

  void _openGitHub() => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GitHubScreen(
          store: app.store,
          onChanged: (gh, sel) {
            app.gh = gh;
            app.poller = BuildPoller(gh);
            app.selection = sel;
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
      body: IndexedStack(index: _tab, children: [
        ChatScreen(
          key: ValueKey(session.created.toIso8601String()),
          router: app.router,
          modelChoices: ['auto', for (final e in app.chain) e.id],
          systemPrompt: s.systemPrompt,
          temperature: s.temperature,
          topP: s.topP,
          maxTokens: s.maxTokens,
          contextMessages: s.contextMessages,
          initial: session.messages,
          onMessagesChanged: _onMessages,
          onOpenSessions: _openSessions,
          onTriggerBuild: _triggerBuild,
          onDownloadArtifact: _downloadArtifact,
          onPickFile: _attachFile,
          toolsEnabled: s.toolsEnabled,
          agentFactory: app.makeAgent,
        ),
        ProvidersScreen(
          providers: app.providers,
          store: app.store,
          client: app.client,
          stats: () => app.router.stats,
          onModeChanged: (_) => app.rebuildChain().then((_) => setState(() {})),
        ),
        ProxyScreen(controller: app.proxy),
        SettingsScreen(
          settings: s,
          files: app.files,
          loadSessions: () async => _sessions,
          importSessions: (list) async {
            setState(() => _sessions.addAll(list));
            await _persist();
          },
          onOpenGitHub: _openGitHub,
        ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) async {
          // Keys may have changed on the Providers tab: refresh the chain on every switch.
          await app.rebuildChain();
          setState(() => _tab = i);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline_rounded), label: 'Chat'),
          NavigationDestination(icon: Icon(Icons.hub_outlined), label: 'Providers'),
          NavigationDestination(icon: Icon(Icons.dns_outlined), label: 'Proxy'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}
