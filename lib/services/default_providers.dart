/// Built-in gateways. The app ships pre-wired to OmniRoute and FreeLLMAPI so
/// chat works out of the box with no manual setup, base URLs or routing.
///
/// Edit the defaults below, or override at build time without touching code:
///   flutter build apk \
///     --dart-define=OMNIROUTE_URL=https://omni.example.com/v1 \
///     --dart-define=OMNIROUTE_KEY=sk-... \
///     --dart-define=FREELLMAPI_URL=https://free.example.com/v1 \
///     --dart-define=FREELLMAPI_KEY=sk-...
///
/// NOTE: `localhost` only works when the gateway runs on the device itself
/// (e.g. in Termux). For a phone-reachable gateway, host it somewhere and set
/// the URLs via --dart-define (or edit the constants here).
class DefaultGateway {
  final String id, name, baseUrl, apiKey;
  const DefaultGateway(this.id, this.name, this.baseUrl, this.apiKey);
}

class DefaultProviders {
  static const omniRoute = DefaultGateway(
    'omniroute',
    'OmniRoute',
    String.fromEnvironment('OMNIROUTE_URL', defaultValue: 'http://localhost:20128/v1'),
    String.fromEnvironment('OMNIROUTE_KEY', defaultValue: 'omniroute'),
  );

  static const freeLlmApi = DefaultGateway(
    'freellmapi',
    'FreeLLMAPI',
    String.fromEnvironment('FREELLMAPI_URL', defaultValue: 'http://localhost:3001/v1'),
    String.fromEnvironment('FREELLMAPI_KEY', defaultValue: 'freellmapi'),
  );

  /// Fallback order: OmniRoute first, FreeLLMAPI second.
  static const all = [omniRoute, freeLlmApi];

  static bool isDefault(String providerId) =>
      all.any((g) => g.id == providerId);

  static String label(String providerId) {
    for (final g in all) {
      if (g.id == providerId) return g.name;
    }
    return providerId;
  }
}
