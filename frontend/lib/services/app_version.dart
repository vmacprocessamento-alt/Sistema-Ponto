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

/// O que o app informa ao servidor ao abrir (POST /me/app-version).
String get reportedAppVersion =>
    appVersion.trim().isEmpty ? 'teste' : appVersion.trim();

/// Build do deploy, com numero (e nao "Versão de teste").
bool hasNumberedAppVersion([String version = appVersion]) =>
    _parseAppVersion(version) != null;

/// (0, 3) para "0.3"; null para "teste", vazio ou outro formato.
(int, int)? _parseAppVersion(String? version) {
  final match =
      RegExp(r'^(\d+)\.(\d+)$').firstMatch((version ?? '').trim());
  if (match == null) return null;
  return (int.parse(match.group(1)!), int.parse(match.group(2)!));
}

/// Na Gestao: a pessoa esta com o app mais velho que o do gestor (que e o do
/// ultimo deploy, porque o app se atualiza sozinho). Sem versao informada
/// conta como desatualizado: e app de antes de existir esse registro. Build de
/// teste (de um lado ou do outro) nao entra na conta.
bool isOutdatedAppVersion(String? reported, [String current = appVersion]) {
  final now = _parseAppVersion(current);
  if (now == null) return false;
  final value = (reported ?? '').trim();
  if (value.isEmpty) return true;
  final theirs = _parseAppVersion(value);
  if (theirs == null) return false;
  return theirs.$1 < now.$1 || (theirs.$1 == now.$1 && theirs.$2 < now.$2);
}
