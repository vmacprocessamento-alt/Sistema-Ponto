import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Mantem a sessao viva entre aberturas do app.
///
/// O Firebase ja persiste a sessao sozinho, mas esse estado local pode ser
/// perdido (limpeza agressiva de dados do fabricante, otimizacao de bateria,
/// reinstalacao). Quando isso acontece guardamos as credenciais cifradas para
/// refazer o login sem o usuario perceber. So o logout explicito apaga.
class SessionService {
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _emailKey = 'session_email';
  static const String _passwordKey = 'session_password';

  /// Tempo maximo esperando o Firebase restaurar a sessao do disco antes de
  /// partir para o login silencioso.
  ///
  /// Quem nao esta logado espera ele inteiro antes de ver o login: com 4 s,
  /// toda abertura deslogada (e todo primeiro acesso no web) parava 4 s na
  /// tela de carregamento. Se a sessao chegar depois do prazo nada se perde:
  /// o AuthGate escuta o authStateChanges e troca o login pela tela do app.
  static const Duration _restoreTimeout = Duration(milliseconds: 1500);

  static Future<void> saveCredentials(String email, String password) async {
    if (kIsWeb) return;
    try {
      await _storage.write(key: _emailKey, value: email.trim());
      await _storage.write(key: _passwordKey, value: password);
    } catch (e) {
      debugPrint('Nao foi possivel guardar a sessao: $e');
    }
  }

  static Future<void> clearCredentials() async {
    if (kIsWeb) return;
    try {
      await _storage.delete(key: _emailKey);
      await _storage.delete(key: _passwordKey);
    } catch (e) {
      debugPrint('Nao foi possivel limpar a sessao: $e');
    }
  }

  static Future<_StoredCredentials?> _readCredentials() async {
    if (kIsWeb) return null;
    try {
      final email = await _storage.read(key: _emailKey);
      final password = await _storage.read(key: _passwordKey);
      if (email == null || email.isEmpty) return null;
      if (password == null || password.isEmpty) return null;
      return _StoredCredentials(email, password);
    } catch (e) {
      debugPrint('Nao foi possivel ler a sessao guardada: $e');
      return null;
    }
  }

  /// Devolve o usuario autenticado, restaurando a sessao se preciso.
  ///
  /// Nunca lanca: se nao der para restaurar, devolve null e a tela de login
  /// aparece normalmente.
  static Future<User?> restoreSession() async {
    final auth = FirebaseAuth.instance;

    final restored = await _waitForPersistedUser(auth);
    if (restored != null) return restored;

    return _silentSignIn(auth);
  }

  /// O Firebase carrega a sessao do disco de forma assincrona. Em aparelho
  /// lento isso pode nao estar pronto no primeiro frame, e ler `currentUser`
  /// direto devolveria null para um usuario que na verdade esta logado.
  static Future<User?> _waitForPersistedUser(FirebaseAuth auth) async {
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

  static Future<User?> _silentSignIn(FirebaseAuth auth) async {
    final credentials = await _readCredentials();
    if (credentials == null) return null;

    try {
      final result = await auth.signInWithEmailAndPassword(
        email: credentials.email,
        password: credentials.password,
      );
      debugPrint('Sessao restaurada com login silencioso.');
      return result.user;
    } on FirebaseAuthException catch (e) {
      // Credencial que nao vale mais (senha trocada, conta removida ou
      // desativada): apaga para nao ficar tentando a cada abertura.
      const invalidCredentialCodes = {
        'user-not-found',
        'wrong-password',
        'invalid-credential',
        'invalid-email',
        'user-disabled',
      };
      if (invalidCredentialCodes.contains(e.code)) {
        debugPrint('Credencial guardada invalida (${e.code}). Limpando.');
        await clearCredentials();
      } else {
        // Falha de rede ou limite de tentativas: mantem o guardado para
        // tentar de novo na proxima abertura.
        debugPrint('Login silencioso falhou (${e.code}). Mantendo credencial.');
      }
      return null;
    } catch (e) {
      debugPrint('Login silencioso falhou: $e');
      return null;
    }
  }
}

class _StoredCredentials {
  final String email;
  final String password;

  const _StoredCredentials(this.email, this.password);
}
