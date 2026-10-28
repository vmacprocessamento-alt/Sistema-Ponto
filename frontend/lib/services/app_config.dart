class AppConfig {
  static const String _apiBaseUrl = String.fromEnvironment('API_BASE_URL');

  /// Endereco do backend. O app e so web: o backend fica no mesmo site, em
  /// /api (o nginx repassa). API_BASE_URL troca isso nos testes locais.
  static String get backendUrl => resolveBackendUrl(_apiBaseUrl, Uri.base);

  static String resolveBackendUrl(String configured, Uri page) {
    final value = configured.trim();
    if (value.isNotEmpty) {
      return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
    }
    return '${page.origin}/api';
  }
}
