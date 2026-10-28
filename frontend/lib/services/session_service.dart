import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

/// Sessao entre aberturas do app.
///
/// No navegador o Firebase guarda a sessao sozinho (IndexedDB) e a carrega de
/// forma assincrona: no primeiro frame `currentUser` pode ainda ser null para
/// quem esta logado. (O login silencioso com a senha guardada no aparelho era
/// do app Android, que saiu em 28/10/2026.)
class SessionService {
  /// Tempo maximo esperando o Firebase restaurar a sessao antes de mostrar o
  /// login. Quem nao esta logado espera ele inteiro; se a sessao chegar depois
  /// do prazo nada se perde: o AuthGate escuta o authStateChanges e troca o
  /// login pela tela do app.
  static const Duration _restoreTimeout = Duration(milliseconds: 1500);

  /// Usuario da sessao guardada, ou null. Nunca lanca.
  static Future<User?> restoreSession() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser != null) return auth.currentUser;
    try {
      return await auth
          .authStateChanges()
          .firstWhere((user) => user != null)
          .timeout(_restoreTimeout);
    } catch (_) {
      return auth.currentUser;
    }
  }
}
