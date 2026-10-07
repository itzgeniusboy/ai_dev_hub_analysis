import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/haptics.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/agent/agent_runner.dart';
import '../../services/agent/agent_tools.dart' show ApprovalRequest;
import '../../services/build_poller.dart';
import '../../services/chat_codec.dart';
import '../../services/router_service.dart';
import 'build_card.dart';
import 'code_block.dart';

sealed class ChatItem {}

class TextItem extends ChatItem {
  final String role; // user | assistant
  String text;
  bool streaming;
  String? error;
  TextItem(this.role, this.text, {this.streaming = false});
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
  final List<String> modelChoices; // e.g. ['auto', 'groq/llama-3.3-70b', ...]
  final String systemPrompt;
  final double temperature, topP;
  final int maxTokens;

  /// Return a status stream (BuildPoller.run(...)) or null if not configured.
  final Stream<BuildStatus>? Function()? onTriggerBuild;
  final Future<void> Function(BuildArtifact)? onDownloadArtifact;
  final VoidCallback? onOpenSessions;
  /// Return text to insert into the composer (e.g. a fenced file), or null.
  final Future<String?> Function()? onPickFile;
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
    this.modelChoices = const ['auto'],
    this.systemPrompt = 'You are a helpful coding assistant.',
    this.temperature = 0.7,
    this.topP = 1.0,
    this.maxTokens = 4096,
    this.onTriggerBuild,
    this.onDownloadArtifact,
    this.onOpenSessions,
    this.onPickFile,
    this.initial = const [],
    this.onMessagesChanged,
    this.contextMessages = 20,
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

  List<Map<String, dynamic>> _history() {
    // Merge consecutive same-role messages (e.g. a user message whose reply
    // failed, or assistant text split around tool calls): some providers
    // reject back-to-back messages with the same role.
    final msgs = <Map<String, dynamic>>[];
    for (final i in _items.whereType<TextItem>()) {
      if (i.text.isEmpty) continue;
      if (msgs.isNotEmpty && msgs.last['role'] == i.role) {
        msgs.last['content'] = '${msgs.last['content']}\n\n${i.text}';
      } else {
        msgs.add({'role': i.role, 'content': i.text});
      }
    }
    final n = widget.contextMessages;
    final recent = msgs.length > n ? msgs.sublist(msgs.length - n) : msgs;
    return [
      {'role': 'system', 'content': widget.systemPrompt},
      ...recent,
    ];
  }

  void _notify() => widget.onMessagesChanged?.call([
        for (final i in _items.whereType<TextItem>())
          if (i.text.isNotEmpty) ChatMsg(i.role, i.text),
      ]);

  Future<void> _attach() async {
    final t = await widget.onPickFile?.call();
    if (t != null && t.isNotEmpty) {
      _input.text = '${_input.text}\n$t'.trimLeft();
    }
  }

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
        }
      });

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    Haptics.send();
    _input.clear();
    final reply = TextItem('assistant', '', streaming: true);
    setState(() {
      _items..add(TextItem('user', text))..add(reply);
    });
    _scrollDown();

    final agent = widget.toolsEnabled ? widget.agentFactory?.call() : null;
    if (widget.toolsEnabled && agent == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Agent tools need a GitHub repo (Settings > GitHub). Sending as plain chat.')));
    }
    if (agent != null) {
      _runAgent(agent, reply);
      return;
    }

    final req = ChatRequest(
      model: _model,
      messages: _history(), // empty assistant placeholder is already excluded
      temperature: widget.temperature,
      topP: widget.topP,
      maxTokens: widget.maxTokens,
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
          temperature: widget.temperature,
          topP: widget.topP,
          maxTokens: widget.maxTokens,
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
                  icon: const Icon(Icons.forum_outlined),
                  onPressed: widget.onOpenSessions),
              title: _ModelPicker(
                  value: _model,
                  choices: widget.modelChoices,
                  onChanged: (m) {
                    Haptics.toggle();
                    setState(() => _model = m);
                  }),
              centerTitle: true,
              actions: [
                IconButton(
                    tooltip: 'Build APK / ZIP',
                    icon: const Icon(Icons.rocket_launch_outlined),
                    onPressed: _build),
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
          onSend: _send,
          onStop: _stop,
          onAttach: widget.onPickFile == null ? null : _attach,
        ),
      ]),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  final String value;
  final List<String> choices;
  final ValueChanged<String> onChanged;
  const _ModelPicker(
      {required this.value, required this.choices, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final c in choices)
          PopupMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis)),
      ],
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
            child: Text(value,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium)),
        const Icon(Icons.expand_more_rounded, size: 20),
      ]),
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
        ? Text(item.text, style: TextStyle(color: cs.onPrimary))
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
  final VoidCallback onSend, onStop;
  final VoidCallback? onAttach;
  const _Composer(
      {required this.controller,
      required this.busy,
      required this.onSend,
      required this.onStop,
      this.onAttach});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: Glass(
          radius: 26,
          padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconButton(
                icon: const Icon(Icons.attach_file_rounded), onPressed: onAttach),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 6,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                    hintText: 'Message',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 12)),
              ),
            ),
            IconButton.filled(
              icon: Icon(busy ? Icons.stop_rounded : Icons.arrow_upward_rounded),
              onPressed: busy ? onStop : onSend,
            ),
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
