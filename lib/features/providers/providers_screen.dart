import 'package:flutter/material.dart';

import '../../core/haptics.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../services/openai_compatible_client.dart';
import '../../services/router_service.dart';
import '../../services/secure_store.dart';

class ProvidersScreen extends StatelessWidget {
  final List<ProviderDef> providers; // from ProviderRegistry.load()
  final SecureStore store;
  final OpenAICompatibleClient client;
  final Map<String, ProviderStats> Function() stats; // router.stats

  const ProvidersScreen({
    super.key,
    required this.providers,
    required this.store,
    required this.client,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Extra providers')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Glass(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_circle_rounded,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'OmniRoute and FreeLLMAPI are built in and already handle routing '
                  'and fallback, so you don\'t need to add anything here.\n\n'
                  'Optional: add your own API key for a provider below and it is used '
                  'as an extra fallback after the built-in gateways.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          for (final p in providers)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ProviderTile(
                def: p,
                store: store,
                client: client,
                stats: () => stats()[p.id],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProviderTile extends StatefulWidget {
  final ProviderDef def;
  final SecureStore store;
  final OpenAICompatibleClient client;
  final ProviderStats? Function() stats;
  const _ProviderTile(
      {required this.def, required this.store, required this.client, required this.stats});

  @override
  State<_ProviderTile> createState() => _ProviderTileState();
}

class _ProviderTileState extends State<_ProviderTile> {
  final _key = TextEditingController();
  final _base = TextEditingController();
  bool _show = false, _testing = false, _loaded = false;
  String? _result; // "✓ 182 ms · 14 models" or error
  bool _ok = false;

  bool get _isCustom => widget.def.id == 'custom';

  @override
  void initState() {
    super.initState();
    () async {
      _key.text = await widget.store.apiKey(widget.def.id) ?? '';
      _base.text = await widget.store.baseUrl(widget.def.id) ?? widget.def.baseUrl;
      if (mounted) setState(() => _loaded = true);
    }();
  }

  @override
  void dispose() {
    _key.dispose();
    _base.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.store.setApiKey(widget.def.id, _key.text.trim());
    if (_isCustom) await widget.store.setBaseUrl(widget.def.id, _base.text.trim());
  }

  Future<void> _test() async {
    Haptics.toggle();
    setState(() {
      _testing = true;
      _result = null;
    });
    await _save();
    final base = _base.text.trim();
    if (base.isEmpty) {
      setState(() {
        _testing = false;
        _ok = false;
        _result = 'Enter a base URL';
      });
      return;
    }
    final ep = Endpoint(
        providerId: widget.def.id, baseUrl: base, apiKey: _key.text.trim(), model: 'test');
    try {
      final sw = Stopwatch()..start();
      final models = await widget.client.listModels(ep);
      _ok = true;
      _result = '${sw.elapsedMilliseconds} ms · ${models.length} models';
      Haptics.copy();
    } on LlmError catch (e) {
      _ok = false;
      _result = e.status == 401 || e.status == 403 ? 'Invalid key (${e.status})' : e.message;
      Haptics.error();
    } catch (e) {
      _ok = false;
      _result = '$e';
      Haptics.error();
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.stats();
    return Glass(
      child: !_loaded
          ? const SizedBox(height: 48)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.def.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (_isCustom) ...[
                TextField(
                  controller: _base,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'Base URL', hintText: 'http://192.168.1.10:20128/v1'),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _key,
                obscureText: !_show,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: widget.def.requiresKey ? 'API key' : 'API key (optional)',
                  suffixIcon: IconButton(
                    icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
                onEditingComplete: _save,
              ),
              const SizedBox(height: 10),
              Row(children: [
                FilledButton.tonal(
                  onPressed: _testing ? null : _test,
                  child: _testing
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Test connection'),
                ),
                const SizedBox(width: 10),
                if (_result != null)
                  Expanded(
                    child: Text(_ok ? '✓ $_result' : '✗ $_result',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _ok ? Colors.green : Theme.of(context).colorScheme.error,
                            fontSize: 12)),
                  ),
              ]),
              if (st != null && st.requests + st.errors > 0) ...[
                const Divider(height: 20),
                Wrap(spacing: 14, runSpacing: 4, children: [
                  _stat(context, 'Latency', '${st.lastLatencyMs} ms'),
                  _stat(context, 'Requests', '${st.requests}'),
                  _stat(context, 'Errors', '${st.errors}'),
                  _stat(context, 'Tokens in', '${st.promptTokens}'),
                  _stat(context, 'Tokens out', '${st.completionTokens}'),
                ]),
              ],
            ]),
    );
  }

  Widget _stat(BuildContext c, String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(k, style: Theme.of(c).textTheme.labelSmall?.copyWith(color: Theme.of(c).hintColor)),
          Text(v, style: Theme.of(c).textTheme.titleSmall),
        ],
      );
}
