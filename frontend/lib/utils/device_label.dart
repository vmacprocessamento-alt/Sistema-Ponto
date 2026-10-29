/// Aparelho em poucas palavras, para a Gestao e o suporte: "iPhone · app
/// instalado", "Android · navegador", "Computador · navegador".
///
/// [installed]: aberto pelo icone da tela inicial (PWA), e nao pelo
/// navegador. [maxTouchPoints]: o iPad recente se apresenta como Mac; so a
/// tela de toque o denuncia.
String describeDevice(String userAgent,
    {bool installed = false, int maxTouchPoints = 0}) {
  final ua = userAgent.toLowerCase();
  final String kind;
  if (ua.contains('iphone') || ua.contains('ipod')) {
    kind = 'iPhone';
  } else if (ua.contains('ipad') ||
      (ua.contains('macintosh') && maxTouchPoints > 1)) {
    kind = 'iPad';
  } else if (ua.contains('android')) {
    kind = 'Android';
  } else if (ua.isEmpty) {
    kind = 'Aparelho desconhecido';
  } else {
    kind = 'Computador';
  }
  return '$kind · ${installed ? 'app instalado' : 'navegador'}';
}
