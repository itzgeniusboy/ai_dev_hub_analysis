/// Embedded gateways (OmniRoute-style and FreeLLMAPI-style).
///
/// They run inside the app on 127.0.0.1 (see local_gateway.dart), so there is
/// nothing to configure. Exactly one is active at a time; [setActive] is
/// called by LocalGateways whenever one starts or stops.
class DefaultGateway {
  final String id, name, baseUrl, apiKey;
  const DefaultGateway(this.id, this.name, this.baseUrl, this.apiKey);
  bool get enabled => baseUrl.trim().isNotEmpty;
}

class DefaultProviders {
  static const omniRouteId = 'omniroute';
  static const freeLlmApiId = 'freellmapi';

  /// Fixed preferred ports (match the real projects' defaults).
  static const omniRoutePort = 20128;
  static const freeLlmApiPort = 3001;

  static DefaultGateway? _active;
  static void setActive(DefaultGateway? g) => _active = g;

  /// The running gateway, or empty while stopped / switching.
  static List<DefaultGateway> get all =>
      _active == null ? const [] : [_active!];

  static bool isDefault(String providerId) =>
      providerId == omniRouteId || providerId == freeLlmApiId;

  static String label(String providerId) => switch (providerId) {
        omniRouteId => 'OmniRoute',
        freeLlmApiId => 'FreeLLMAPI',
        _ => providerId,
      };
}
