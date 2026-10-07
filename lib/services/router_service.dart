import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import 'openai_compatible_client.dart';

/// Direct-mode router: ordered fallback across the providers the user has keys for.
/// (Gateway mode = just point a Custom endpoint at OmniRoute / FreeLLMAPI with model "auto".)
class RouterService {
  final OpenAICompatibleClient client;
  final List<Endpoint> Function() chain; // user's ordered targets (keys resolved)
  final Map<String, DateTime> _cooldownUntil = {};
  final Map<String, ProviderStats> stats = {};

  RouterService({required this.client, required this.chain});

  bool _cooling(Endpoint e) {
    final t = _cooldownUntil[e.id];
    return t != null && DateTime.now().isBefore(t);
  }

  void _cool(Endpoint e, Duration d) =>
      _cooldownUntil[e.id] = DateTime.now().add(d);

  /// Streams raw SSE payloads from the first healthy target.
  /// Fails over ONLY before the first payload is emitted — after that, switching
  /// providers would duplicate/garble output, so the error is rethrown instead.
  Stream<String> stream(ChatRequest req, {CancelToken? cancel}) async* {
    Object? lastError;
    final candidates = chain().where((e) {
      // A specific model request pins to that model; "auto" uses the whole chain.
      return req.model == 'auto' || e.model == req.model || e.id == req.model;
    }).toList();

    if (candidates.isEmpty) {
      throw AllProvidersFailed(
          null,
          req.model == 'auto'
              ? 'No providers configured. Add an API key in the Providers tab.'
              : 'No provider matches "${req.model}". Pick "auto" or add its key in Providers.');
    }

    var skipped = 0;
    for (final e in candidates) {
      if (_cooling(e)) {
        skipped++;
        continue;
      }
      final s = stats.putIfAbsent(e.providerId, ProviderStats.new);
      final sw = Stopwatch()..start();
      final it = StreamIterator(client.streamRaw(e, req, cancel: cancel));
      var emitted = false;
      var prompt = 0, completion = 0;
      try {
        while (await it.moveNext()) {
          final p = it.current;
          if (!emitted) {
            emitted = true;
            s.lastLatencyMs = sw.elapsedMilliseconds;
          }
          final usage = _usageOf(p);
          if (usage != null) {
            prompt = usage.$1;
            completion = usage.$2;
          }
          yield p;
        }
        s.record(
            latencyMs: s.lastLatencyMs, prompt: prompt, completion: completion);
        return; // success
      } on RateLimitError catch (err) {
        s.errors++;
        _cool(e, err.retryAfter);
        lastError = err;
        if (emitted) rethrow;
      } on TransientError catch (err) {
        s.errors++;
        _cool(e, const Duration(seconds: 20));
        lastError = err;
        if (emitted) rethrow;
      } on FatalError catch (err) {
        s.errors++;
        _cool(e, const Duration(minutes: 5)); // bad key / model: stop hammering
        lastError = err;
        if (emitted) rethrow;
      } finally {
        await it.cancel();
      }
    }
    if (lastError == null && skipped > 0) {
      throw const AllProvidersFailed(null,
          'All matching providers are cooling down after recent errors. Try again shortly.');
    }
    throw AllProvidersFailed(lastError);
  }

  static (int, int)? _usageOf(String payload) {
    if (payload == '[DONE]' || !payload.contains('"usage"')) return null;
    try {
      final u = (jsonDecode(payload) as Map)['usage'] as Map?;
      if (u == null) return null;
      return ((u['prompt_tokens'] ?? 0) as int, (u['completion_tokens'] ?? 0) as int);
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Remote provider registry: new base URLs / model IDs without an app update.
// ---------------------------------------------------------------------------

class ProviderDef {
  final String id, name, baseUrl;
  final List<String> models;
  final bool requiresKey;
  ProviderDef.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        name = j['name'],
        baseUrl = j['baseUrl'],
        models = List<String>.from(j['models'] ?? const []),
        requiresKey = j['requiresKey'] ?? true;
}

/// Point [registryUrl] at a raw JSON file you control, e.g.
/// https://raw.githubusercontent.com/<you>/<repo>/main/providers.json
/// Schema: { "version": 3, "providers": [ {id,name,baseUrl,models[],requiresKey} ] }
///
/// Strategy: ETag-cached fetch -> save to prefs -> fall back to last good copy
/// -> fall back to bundled asset. Add Ed25519 verification of the file before
/// trusting it if the URL is not under your control.
class ProviderRegistry {
  static const _cacheKey = 'provider_registry_json';
  static const _etagKey = 'provider_registry_etag';
  final String registryUrl;
  final Dio _dio;
  ProviderRegistry(this.registryUrl, [Dio? dio]) : _dio = dio ?? Dio();

  Future<List<ProviderDef>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final etag = prefs.getString(_etagKey);
      final res = await _dio.get<String>(registryUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: {if (etag != null) 'If-None-Match': etag},
            validateStatus: (s) => s == 200 || s == 304,
            receiveTimeout: const Duration(seconds: 8),
          ));
      if (res.statusCode == 200 && res.data != null) {
        _parse(res.data!); // throws if malformed -> keeps old cache
        await prefs.setString(_cacheKey, res.data!);
        final newEtag = res.headers.value('etag');
        if (newEtag != null) await prefs.setString(_etagKey, newEtag);
      }
    } catch (_) {/* offline or bad file: use cache/bundled */}

    final cached = prefs.getString(_cacheKey);
    if (cached != null) {
      try {
        return _parse(cached);
      } catch (_) {}
    }
    return _parse(await rootBundle.loadString('assets/providers.json'));
  }

  List<ProviderDef> _parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return (j['providers'] as List)
        .map((p) => ProviderDef.fromJson(p as Map<String, dynamic>))
        .toList();
  }
}

/// Live model sync for gateway mode: ask OmniRoute/FreeLLMAPI what it serves now.
Future<List<String>> syncGatewayModels(
        OpenAICompatibleClient client, Endpoint gateway) =>
    client.listModels(gateway);
