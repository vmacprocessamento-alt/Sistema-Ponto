import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/login_reason.dart';

/// Por que o login apareceu (19/11/2026): achar por que o pessoal do Android
/// caia no login sem tocar em Sair.
void main() {
  test('tocou em Sair', () {
    expect(loginReasonFrom(logoutByUser: true, cachedUser: '{}', lastLogin: 'x'),
        'manual_logout');
    // App antigo, sem a marca: o Sair apaga o perfil e deixa o CPF.
    expect(loginReasonFrom(logoutByUser: false, lastLogin: '529.982.247-25'),
        'manual_logout');
  });

  test('estava logado aqui e caiu no login', () {
    expect(
        loginReasonFrom(
            logoutByUser: false,
            cachedUser: '{"id":"u1"}',
            lastLogin: '529.982.247-25'),
        'session_lost');
  });

  test('navegador sem nenhum dado do app', () {
    expect(loginReasonFrom(logoutByUser: false), 'new_browser');
    expect(loginReasonFrom(logoutByUser: false, cachedUser: '', lastLogin: ''),
        'new_browser');
  });
}
