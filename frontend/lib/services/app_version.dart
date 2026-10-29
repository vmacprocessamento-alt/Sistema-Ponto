/// Versao do app que esta rodando neste aparelho: 0.1, 0.2, 0.3... Sobe
/// sozinha a cada deploy (deploy/atualizar.sh, --dart-define=APP_VERSION).
/// Aparece no Perfil e no login: no suporte, da para saber na hora se o
/// celular da pessoa ja atualizou (compare com a do ultimo deploy).
const String appVersion = String.fromEnvironment('APP_VERSION');

/// "Versão 0.3". Build feito a mao, sem o numero: "Versão de teste".
String appVersionLabel([String version = appVersion]) {
  final value = version.trim();
  return value.isEmpty ? 'Versão de teste' : 'Versão $value';
}
