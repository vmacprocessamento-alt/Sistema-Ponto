/// Por que o login apareceu neste navegador (19/11/2026), pelos dados que o
/// app guarda nele, lidos ANTES do login (que regrava o perfil):
///   - 'manual_logout': a pessoa tocou em Sair ([logoutByUser]); no app antigo,
///     sem a marca, o Sair apaga o perfil e deixa o ultimo CPF;
///   - 'session_lost': o perfil ainda esta aqui, mas a sessao sumiu (dados de
///     login apagados pelo navegador ou sessao derrubada);
///   - 'new_browser': nenhum dado do app (dados do site apagados, outro
///     navegador ou primeiro acesso nele).
String loginReasonFrom({
  required bool logoutByUser,
  String? cachedUser,
  String? lastLogin,
}) {
  if (logoutByUser) return 'manual_logout';
  if (cachedUser != null && cachedUser.isNotEmpty) return 'session_lost';
  if (lastLogin != null && lastLogin.isNotEmpty) return 'manual_logout';
  return 'new_browser';
}
