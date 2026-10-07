/// Optional self-hosted gateways (OmniRoute, FreeLLMAPI).
///
/// These are NOT active unless you give them a reachable URL, because
/// `localhost` on a phone is the phone itself and nothing listens there.
/// Enable at build time:
///   flutter build apk \
///     --dart-define=OMNIROUTE_URL=https://omni.example.com/v1 \
///     --dart-define=OMNIROUTE_KEY=sk-... \
///     --dart-define=FREELLMAPI_URL=https://free.example.com/v1 \
///     --dart-define=FREELLMAPI_KEY=sk-...
///
/// With no URLs set, chat uses the internet providers from providers.json
/// (Pollinations works with no key; add Groq/Gemini/OpenRouter keys for more).
class DefaultGateway {
  final String id, name, baseUrl, apiKey;
  const DefaultGateway(this.id, this.name, this.baseUrl, this.apiKey);
  bool get enabled => baseUrl.trim().isNotEmpty;
}

class DefaultProviders {
  static const omniRoute = DefaultGateway(
    'omniroute',
    'OmniRoute',
    String.fromEnvironment('OMNIROUTE_URL'),
    String.fromEnvironment('OMNIROUTE_KEY', defaultValue: 'omniroute'),
  );

  static const freeLlmApi = DefaultGateway(
    'freellmapi',
    'FreeLLMAPI',
    String.fromEnvironment('FREELLMAPI_URL'),
    String.fromEnvironment('FREELLMAPI_KEY', defaultValue: 'freellmapi'),
  );

  /// Only gateways that have a URL configured.
  static List<DefaultGateway> get all =>
      [omniRoute, freeLlmApi].where((g) => g.enabled).toList();

  static bool isDefault(String providerId) =>
      providerId == omniRoute.id || providerId == freeLlmApi.id;

  static String label(String providerId) {
    for (final g in [omniRoute, freeLlmApi]) {
      if (g.id == providerId) return g.name;
    }
    return providerId;
  }
}
