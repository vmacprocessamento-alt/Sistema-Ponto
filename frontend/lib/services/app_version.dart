/// Versao do app que esta rodando neste aparelho, carimbada no build pelo
/// deploy (deploy/atualizar.sh: --dart-define=APP_BUILD=<commit>-<AAAAMMDDHHMMSS>,
/// o mesmo carimbo do service worker). Aparece no Perfil e no login: no
/// suporte, da para saber na hora se o celular da pessoa ja atualizou.
const String appBuild = String.fromEnvironment('APP_BUILD');

/// "29/10/2026 14:32 (b27c4cb)": data e hora do deploy e o commit.
/// Build feito a mao, sem o carimbo: "build local".
String appVersionLabel([String build = appBuild]) {
  final match = RegExp(r'^([0-9a-f]{4,40})-(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})\d{2}$')
      .firstMatch(build.trim());
  if (match == null) return build.trim().isEmpty ? 'build local' : build.trim();
  final commit = match.group(1);
  final year = match.group(2);
  final month = match.group(3);
  final day = match.group(4);
  final hour = match.group(5);
  final minute = match.group(6);
  return '$day/$month/$year $hour:$minute ($commit)';
}
