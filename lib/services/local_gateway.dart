import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'default_providers.dart';
import 'openai_compatible_client.dart';
import 'proxy_server.dart';
import 'router_service.dart';
import 'secure_store.dart';

enum GatewayKind { omniRoute, freeLlmApi }

extension GatewayKindX on GatewayKind {
  String get id => this == GatewayKind.omniRoute
      ? DefaultProviders.omniRouteId
      : DefaultProviders.freeLlmApiId;
  String get label => DefaultProviders.label(id);
  int get preferredPort => this == GatewayKind.omniRoute
      ? DefaultProviders.omniRoutePort
      : DefaultProviders.freeLlmApiPort;
  String get blurb => this == GatewayKind.omniRoute
      ? 'Health-aware: fastest healthy provider first, circuit breakers on failures.'
      : 'Fallback chain: providers in fixed order, with a per-minute request cap.';
}

/// How an embedded gateway orders its healthy upstream targets.
abstract class GatewayPolicy {
  List<Endpoint> order(List<Endpoint> targets);
  void onAttempt(Endpoint e) {}
}

/// OmniRoute-style: proven-fast providers first, untested next, flaky last.
/// (Hard failures are additionally circuit-broken by RouterService cooldowns.)
class OmniRoutePolicy extends GatewayPolicy {
  final Map<String, ProviderStats> stats;
  OmniRoutePolicy(this.stats);

  double _score(Endpoint e) {
    final s = stats[e.providerId];
    if (s == null || s.requests + s.errors == 0) return 0.5; // untested
    final errRate = s.errors / (s.requests + s.errors);
    if (errRate > 0.5) return 1 + errRate; // flaky
    return s.lastLatencyMs / 1e6; // proven: fastest first
  }

  @override
  List<Endpoint> order(List<Endpoint> targets) {
    final idx = {for (var i = 0; i < targets.length; i++) targets[i]: i};
    final out = [...targets];
    out.sort((a, b) {
      final c = _score(a).compareTo(_score(b));
      return c != 0 ? c : idx[a]!.compareTo(idx[b]!); // stable
    });
    return out;
  }
}

/// FreeLLMAPI-style: strict configured order; a provider that has used up its
/// per-minute budget is moved to the back instead of being hammered.
class FreeLlmApiPolicy extends GatewayPolicy {
  final int rpm;
  final Map<String, List<DateTime>> _hits = {};
  FreeLlmApiPolicy({this.rpm = 30});

  int _recent(String providerId) {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    final l = _hits[providerId] ?? [];
    l.removeWhere((t) => t.isBefore(cutoff));
    return l.length;
  }

  @override
  List<Endpoint> order(List<Endpoint> targets) => [
        ...targets.where((e) => _recent(e.providerId) < rpm),
        ...targets.where((e) => _recent(e.providerId) >= rpm),
      ];

  @override
  void onAttempt(Endpoint e) =>
      _hits.putIfAbsent(e.providerId, () => []).add(DateTime.now());
}

/// Runs one embedded gateway at a time on loopback. Switching stops the
/// current server, then starts the other. OmniRoute is the default.
class LocalGateways extends ChangeNotifier {
  final OpenAICompatibleClient client;
  final SecureStore store;
  final Map<String, ProviderStats> stats;
  final List<Endpoint> Function() upstream; // real providers (keys resolved)
  final Future<void> Function() onChanged; // app rebuilds its chain

  LocalGateways({
    required this.client,
    required this.store,
    required this.stats,
    required this.upstream,
    required this.onChanged,
  });

  GatewayKind kind = GatewayKind.omniRoute;
  bool busy = false;
  String? error;
  int? port;
  ProxyServer? _server;
  RouterService? _router;
  String _token = '';

  bool get running => _server?.running ?? false;

  Future<void> init() async {
    final saved = await store.gatewayKind();
    kind = saved == GatewayKind.freeLlmApi.name
        ? GatewayKind.freeLlmApi
        : GatewayKind.omniRoute;
    var t = await store.gatewayToken();
    if (t == null || t.isEmpty) {
      t = ProxyServer.generateToken();
      await store.setGatewayToken(t);
    }
    _token = t;
    await _start();
  }

  void resetCooldowns() => _router?.resetCooldowns();

  Future<void> _start() async {
    final k = kind;
    final policy = k == GatewayKind.omniRoute
        ? OmniRoutePolicy(stats) as GatewayPolicy
        : FreeLlmApiPolicy();
    final router = RouterService(
      client: client,
      chain: upstream,
      stats: stats,
      order: policy.order,
      onAttempt: policy.onAttempt,
    );
    final server = ProxyServer(
      router: router,
      modelIds: () => [for (final e in upstream()) e.id],
      token: _token,
      allowAppOrigin: true,
      label: '${k.label} (embedded gateway)',
    );
    int p;
    try {
      p = await server.start(port: k.preferredPort);
    } on SocketException {
      p = await server.start(port: 0); // preferred port taken: any free one
    }
    _router = router;
    _server = server;
    port = p;
    error = null;
    DefaultProviders.setActive(
        DefaultGateway(k.id, k.label, 'http://127.0.0.1:$p/v1', _token));
  }

  Future<void> _stop() async {
    DefaultProviders.setActive(null); // chat falls back to direct meanwhile
    await _server?.stop();
    _server = null;
    _router = null;
    port = null;
  }

  /// Stops the running gateway and starts [k]. Safe to call repeatedly.
  Future<void> switchTo(GatewayKind k) async {
    if (busy || (k == kind && running)) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _stop();
      kind = k;
      await store.setGatewayKind(k.name);
      await _start();
    } catch (e) {
      error = '${k.label} failed to start: $e';
    } finally {
      busy = false;
      notifyListeners();
      await onChanged();
    }
  }
}
