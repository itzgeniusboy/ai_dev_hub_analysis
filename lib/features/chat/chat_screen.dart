import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../core/haptics.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/agent/agent_runner.dart';
import '../../services/agent/agent_tools.dart' show ApprovalRequest;
import '../../services/build_poller.dart';
import '../../services/chat_codec.dart';
import '../../services/default_providers.dart';
import '../../services/router_service.dart';
import '../../services/skill_store.dart';
import 'build_card.dart';
import 'code_block.dart';

sealed class ChatItem {}

/// A photo attached to the next message (kept as a data: URL for vision models).
class Attachment {
  final String name, dataUrl;
  const Attachment(this.name, this.dataUrl);
}

class TextItem extends ChatItem {
  final String role; // user | assistant
  String text;
  bool streaming;
  String? error;
  final List<Attachment> images;
  TextItem(this.role, this.text,
      {this.streaming = false, this.images = const []});
}

class BuildItem extends ChatItem {
  final Stream<BuildStatus> status;
  BuildItem(this.status);
}

/// One tool call made by the agent (ok == null while it runs).
class ToolItem extends ChatItem {
  final String id, name, label;
  String? summary;
  bool? ok;
  ToolItem(this.id, this.name, this.label);
}

/// Wire-up is by callbacks so this screen stays independent of your DI choice.
class ChatScreen extends StatefulWidget {
  final RouterService router;

  /// Models that are configured and currently reachable. Evaluated each time
  /// the model menu opens, so it always reflects what is available right now.
  final List<Endpoint> Function() models;
  final VoidCallback? onModelMenuOpen; // e.g. refresh the live model list
  final String systemPrompt;
  final SkillStore skills;
  final VoidCallback? onManageSkills;

  /// Return a status stream (BuildPoller.run(...)) or null if not configured.
  final Stream<BuildStatus>? Function()? onTriggerBuild;
  final Future<void> Function(BuildArtifact)? onDownloadArtifact;
  final VoidCallback? onOpenMenu; // side menu (chats, skills, connectors, settings)
  final VoidCallback? onNewChat;
  final VoidCallback? onOpenGitHub;
  final bool githubConnected;

  /// Return text to insert into the composer (e.g. a fenced file), or null.
  final Future<String?> Function()? onPickFile;
  final Future<Attachment?> Function()? onPickPhoto;
  final List<ChatMsg> initial;
  final ValueChanged<List<ChatMsg>>? onMessagesChanged;
  final int contextMessages;

  /// Agent mode: when [toolsEnabled], each send goes through the tool loop
  /// built by [agentFactory] (null return = tools unavailable, plain chat).
  final bool toolsEnabled;
  final AgentRunner? Function()? agentFactory;

  const ChatScreen({
    super.key,
    required this.router,
    required this.models,
    required this.skills,
    this.onModelMenuOpen,
    this.onManageSkills,
    this.systemPrompt = 'You are a helpful coding assistant.',
    this.onTriggerBuild,
    this.onDownloadArtifact,
    this.onOpenMenu,
    this.onNewChat,
    this.onOpenGitHub,
    this.githubConnected = false,
    this.onPickFile,
    this.onPickPhoto,
    this.initial = const [],
    this.onMessagesChanged,
    this.contextMessages = 30,
    this.toolsEnabled = false,
    this.agentFactory,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _items = <ChatItem>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<dynamic>? _sub;
  AgentRunner? _agent;
  String _model = 'auto';
  final _pending = <Attachment>[];
  bool get _busy => _sub != null;

  @override
  void dispose() {
    _agent?.cancel();
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    for (final m in widget.initial) {
      _items.add(TextItem(m.role, m.text));
    }
  }

  Object _content(TextItem i) => i.images.isEmpty
      ? i.text
      : [
          {'type': 'text', 'text': i.text.isEmpty ? 'Describe this image.' : i.text},
          for (final img in i.images)
            {'type': 'image_url', 'image_url': {'url': img.dataUrl}},
        ];

  List<Map<String, dynamic>> _history() {
    // Merge consecutive same-role text messages (e.g. a user message whose reply
    // failed, or assistant text split around tool calls): some providers
    // reject back-to-back messages with the same role. Messages with photos
    // are never merged.
    final msgs = <Map<String, dynamic>>[];
    for (final i in _items.whereType<TextItem>()) {
      if (i.text.isEmpty && i.images.isEmpty) continue;
      final c = _content(i);
      if (msgs.isNotEmpty &&
          msgs.last['role'] == i.role &&
          msgs.last['content'] is String &&
          c is String) {
        msgs.last['content'] = '${msgs.last['content']}\n\n$c';
      } else {
        msgs.add({'role': i.role, 'content': c});
      }
    }
    final n = widget.contextMessages;
    final recent = msgs.length > n ? msgs.sublist(msgs.length - n) : msgs;
    return [
      {'role': 'system', 'content': '${widget.systemPrompt}${widget.skills.promptAddendum}'},
      ...recent,
    ];
  }

  void _notify() => widget.onMessagesChanged?.call([
        for (final i in _items.whereType<TextItem>())
          if (i.text.isNotEmpty || i.images.isNotEmpty)
            ChatMsg(i.role, [
              i.text,
              for (final img in i.images) '[Photo: ${img.name}]',
            ].where((x) => x.isNotEmpty).join('\n')),
      ]);

  Future<void> _attach() async {
    final t = await widget.onPickFile?.call();
    if (t != null && t.isNotEmpty) {
      _input.text = '${_input.text}\n$t'.trimLeft();
    }
  }

  Future<void> _attachPhoto() async {
    final a = await widget.onPickPhoto?.call();
    if (a != null && mounted) setState(() => _pending.add(a));
  }

  void _plusMenu() {
    Haptics.toggle();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: widget.skills,
          builder: (_, __) {
            final skills = widget.skills.skills;
            return SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (widget.onPickFile != null)
                  ListTile(
                    leading: const Icon(Icons.attach_file_rounded),
                    title: const Text('Upload file'),
                    subtitle: const Text('Text or code, up to 200 KB'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _attach();
                    },
                  ),
                if (widget.onPickPhoto != null)
                  ListTile(
                    leading: const Icon(Icons.photo_outlined),
                    title: const Text('Upload photo'),
                    subtitle: const Text('Needs a model that supports images'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _attachPhoto();
                    },
                  ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(children: [
                    Expanded(
                        child: Text('Skills',
                            style: Theme.of(ctx).textTheme.titleSmall)),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        widget.onManageSkills?.call();
                      },
                      child: const Text('Manage'),
                    ),
                  ]),
                ),
                if (skills.isEmpty)
                  ListTile(
                    leading: const Icon(Icons.add_rounded),
                    title: const Text('Add a skill'),
                    onTap: () {
                      Navigator.pop(ctx);
                      widget.onManageSkills?.call();
                    },
                  ),
                for (final k in skills)
                  SwitchListTile(
                    dense: true,
                    title: Text(k.name),
                    value: k.enabled,
                    onChanged: (v) {
                      Haptics.toggle();
                      widget.skills.setEnabled(k, v);
                    },
                  ),
                const SizedBox(height: 8),
              ]),
            );
          },
        ),
      ),
    );
  }

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
        }
      });

  void _send() {
    final text = _input.text.trim();
    if ((text.isEmpty && _pending.isEmpty) || _busy) return;
    Haptics.send();
    _input.clear();

    // A model that dropped out (rate-limited / unreachable) falls back to Auto.
    if (_model != 'auto' &&
        !widget.models().any((e) => e.id == _model)) {
      _model = 'auto';
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That model is unavailable right now. Using Auto.')));
    }

    final reply = TextItem('assistant', '', streaming: true);
    final imgs = List<Attachment>.of(_pending);
    setState(() {
      _pending.clear();
      _items..add(TextItem('user', text, images: imgs))..add(reply);
    });
    _scrollDown();

    final agent = widget.toolsEnabled ? widget.agentFactory?.call() : null;
    if (widget.toolsEnabled && agent == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Agent tools need a GitHub repo (tap the GitHub icon) Device file access or Terminal in Settings. Sending as plain chat.')));
    }
    if (agent != null) {
      _runAgent(agent, reply);
      return;
    }

    final req = ChatRequest(
      model: _model,
      messages: _history(), // empty assistant placeholder is already excluded
    );

    _sub = widget.router.stream(req).listen(
      (payload) {
        final d = _delta(payload);
        if (d == null) return;
        setState(() => reply.text += d);
        _scrollDown();
      },
      onError: (e) {
        Haptics.error();
        setState(() {
          reply.error = '$e';
          reply.streaming = false;
          _sub = null;
        });
        _notify();
      },
      onDone: () {
        setState(() {
          reply.streaming = false;
          if (reply.text.isEmpty && reply.error == null) {
            reply.error = 'The model returned an empty response.';
          }
          _sub = null;
        });
        _notify();
      },
    );
  }

  Future<bool> _approve(ApprovalRequest r) async {
    if (!mounted) return false;
    Haptics.toggle();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(r.title),
        content: SingleChildScrollView(
          child: Text(r.detail,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Deny')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Approve')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Drives one agent turn. Assistant text, tool calls and build cards are
  /// appended to the list in the order they happen.
  void _runAgent(AgentRunner agent, TextItem first) {
    _agent = agent;
    TextItem? cur = first; // bubble currently receiving streamed text
    var usedTools = false;

    void finish() {
      final c = cur;
      if (c != null) {
        c.streaming = false;
        if (c.text.isEmpty && c.error == null) {
          if (usedTools) {
            _items.remove(c);
          } else {
            c.error = 'The model returned an empty response.';
          }
        }
      }
      _agent = null;
      _sub = null;
    }

    _sub = agent
        .run(
          messages: _history(),
          model: _model,
          approve: _approve,
        )
        .listen(
      (e) {
        switch (e) {
          case AgentText(:final delta):
            setState(() {
              if (cur == null) {
                cur = TextItem('assistant', '', streaming: true);
                _items.add(cur!);
              }
              cur!.text += delta;
            });
            _scrollDown();
          case AgentToolStart(:final id, :final name, :final label):
            usedTools = true;
            setState(() {
              final c = cur;
              if (c != null) {
                c.streaming = false;
                if (c.text.isEmpty) _items.remove(c);
              }
              cur = null;
              _items.add(ToolItem(id, name, label));
            });
            _scrollDown();
          case AgentToolDone(:final id, :final ok, :final summary):
            setState(() {
              for (final t in _items.whereType<ToolItem>()) {
                if (t.id == id) {
                  t.ok = ok;
                  t.summary = summary;
                }
              }
              // Spinner while the model reads the tool result.
              cur = TextItem('assistant', '', streaming: true);
              _items.add(cur!);
            });
            _scrollDown();
          case AgentBuild(:final status):
            setState(() => _items.add(BuildItem(status.asBroadcastStream())));
            _scrollDown();
          case AgentNotice(:final text):
            setState(() {
              final c = cur;
              if (c != null && c.text.isEmpty) _items.remove(c);
              cur = TextItem('assistant', text);
              _items.add(cur!);
            });
            _scrollDown();
        }
      },
      onError: (Object err) {
        Haptics.error();
        setState(() {
          if (cur == null) {
            cur = TextItem('assistant', '');
            _items.add(cur!);
          }
          cur!.error = '$err';
          finish();
        });
        _notify();
      },
      onDone: () {
        setState(finish);
        _notify();
      },
    );
  }

  String? _delta(String payload) {
    if (payload == '[DONE]') return null;
    try {
      final ch = (jsonDecode(payload) as Map)['choices'] as List?;
      if (ch == null || ch.isEmpty) return null;
      final c = ((ch.first as Map)['delta'] as Map?)?['content'];
      return c is String ? c : null;
    } catch (_) {
      return null;
    }
  }

  void _stop() {
    _agent?.cancel();
    _agent = null;
    _sub?.cancel();
    setState(() {
      if (_items.isNotEmpty && _items.last is TextItem) {
        final t = _items.last as TextItem;
        t.streaming = false;
        if (t.text.isEmpty && t.error == null) _items.removeLast();
      }
      _sub = null;
    });
    _notify();
  }

  void _build() {
    final s = widget.onTriggerBuild?.call();
    if (s == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Connect GitHub and choose a repo first')));
      return;
    }
    Haptics.toggle();
    setState(() => _items.add(BuildItem(s.asBroadcastStream())));
    _scrollDown();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: AppBar(
              leading: IconButton(
                  tooltip: 'Menu',
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: widget.onOpenMenu),
              title: _ModelPicker(
                value: _model,
                choices: () => widget.models(),
                onOpen: widget.onModelMenuOpen,
                onChanged: (m) {
                  Haptics.toggle();
                  setState(() => _model = m);
                },
              ),
              centerTitle: true,
              actions: [
                IconButton(
                  tooltip: 'GitHub',
                  onPressed: widget.onOpenGitHub,
                  icon: Stack(clipBehavior: Clip.none, children: [
                    const FaIcon(FontAwesomeIcons.github, size: 22),
                    if (widget.githubConnected)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: const Color(0xFF30D158),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: Theme.of(context).colorScheme.surface,
                                width: 1.5),
                          ),
                        ),
                      ),
                  ]),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (v) {
                    if (v == 'new') widget.onNewChat?.call();
                    if (v == 'build') _build();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'new',
                        child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.add_comment_outlined),
                            title: Text('New chat'))),
                    PopupMenuItem(
                        value: 'build',
                        child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.rocket_launch_outlined),
                            title: Text('Build APK / ZIP'))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
                12, MediaQuery.of(context).padding.top + kToolbarHeight + 8, 12, 12),
            itemCount: _items.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: switch (_items[i]) {
                final TextItem t => _Bubble(item: t),
                final ToolItem t => _ToolRow(item: t),
                final BuildItem b => BuildCard(
                    status: b.status,
                    onDownload: widget.onDownloadArtifact ?? (_) async {}),
              },
            ),
          ),
        ),
        _Composer(
          controller: _input,
          busy: _busy,
          pending: _pending,
          onRemovePending: (a) => setState(() => _pending.remove(a)),
          onSend: _send,
          onStop: _stop,
          onPlus: _plusMenu,
        ),
      ]),
    );
  }
}

String modelLabel(String id) {
  if (id == 'auto') return 'Auto';
  final i = id.indexOf('/');
  if (i < 0) return id;
  final provider = DefaultProviders.label(id.substring(0, i));
  final model = id.substring(i + 1);
  return '$provider · ${model == 'auto' ? 'Auto' : model}';
}

/// Compact model switcher. Lists only models that are configured and not
/// currently failing; the list is rebuilt every time the menu opens.
class _ModelPicker extends StatelessWidget {
  final String value;
  final List<Endpoint> Function() choices;
  final VoidCallback? onOpen;
  final ValueChanged<String> onChanged;
  const _ModelPicker(
      {required this.value,
      required this.choices,
      required this.onChanged,
      this.onOpen});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: 'Switch model',
      onOpened: onOpen,
      onSelected: onChanged,
      constraints: const BoxConstraints(maxWidth: 320),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'auto',
          child: Row(children: [
            Expanded(
                child: Text('Auto (best available)',
                    overflow: TextOverflow.ellipsis)),
            if (value == 'auto') const Icon(Icons.check_rounded, size: 18),
          ]),
        ),
        for (final e in choices())
          PopupMenuItem(
            value: e.id,
            child: Row(children: [
              Expanded(
                  child: Text(modelLabel(e.id), overflow: TextOverflow.ellipsis)),
              if (value == e.id) const Icon(Icons.check_rounded, size: 18),
            ]),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(modelLabel(value),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: cs.onSurface))),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 18, color: cs.onSurface),
        ]),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final TextItem item;
  const _Bubble({required this.item});

  @override
  Widget build(BuildContext context) {
    final isUser = item.role == 'user';
    final cs = Theme.of(context).colorScheme;
    final maxW = MediaQuery.of(context).size.width * (isUser ? 0.82 : 0.96);

    final content = isUser
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final img in item.images)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.photo_outlined, size: 16, color: cs.onPrimary),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(img.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.onPrimary))),
                ]),
              ),
            if (item.text.isNotEmpty)
              Text(item.text, style: TextStyle(color: cs.onPrimary)),
          ])
        : item.text.isEmpty && item.error == null
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MarkdownBody(
                  data: item.text + (item.streaming ? ' ▍' : ''),
                  selectable: false, // selectable + builders conflict; code has copy buttons
                  builders: {'code': CodeBlockBuilder()},
                ),
                if (item.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(item.error!,
                        style: TextStyle(color: cs.error, fontSize: 12)),
                  ),
              ]);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: isUser
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                    color: cs.primary, borderRadius: BorderRadius.circular(20)),
                child: content)
            : Glass(radius: 20, child: content),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final List<Attachment> pending;
  final ValueChanged<Attachment> onRemovePending;
  final VoidCallback onSend, onStop, onPlus;
  const _Composer(
      {required this.controller,
      required this.busy,
      required this.pending,
      required this.onRemovePending,
      required this.onSend,
      required this.onStop,
      required this.onPlus});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Glass(
          radius: 26,
          padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (pending.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final a in pending)
                      InputChip(
                        avatar: Icon(Icons.photo_outlined,
                            size: 16, color: cs.onSurface),
                        label: Text(a.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: cs.onSurface)),
                        onDeleted: () => onRemovePending(a),
                      ),
                  ]),
                ),
              ),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                  tooltip: 'Add files, photos and skills',
                  icon: const Icon(Icons.add_circle_outline_rounded),
                  onPressed: onPlus),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(color: cs.onSurface),
                  decoration: InputDecoration(
                      hintText: 'Message',
                      hintStyle: TextStyle(color: cs.onSurfaceVariant),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              IconButton.filled(
                icon: Icon(busy ? Icons.stop_rounded : Icons.arrow_upward_rounded),
                onPressed: busy ? onStop : onSend,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  final ToolItem item;
  const _ToolRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = item.ok;
    final Widget leading = ok == null
        ? const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
            size: 18, color: ok ? cs.primary : cs.error);
    return Align(
      alignment: Alignment.centerLeft,
      child: Glass(
        radius: 14,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          leading,
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.label,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              if (item.summary != null)
                Text(item.summary!,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }
}
