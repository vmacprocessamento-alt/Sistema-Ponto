import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/services/api_service.dart';

void main() {
  test('perfil com nome, e-mail, cargo ou CPF vale', () {
    expect(
        ApiService.isCompleteProfile({
          'id': 'u1',
          'name': 'Rodrigo Rodrigues',
          'role': 'admin',
        }),
        isTrue);
    expect(ApiService.isCompleteProfile({'id': 'u1', 'cpf': '025.805.531-69'}),
        isTrue);
  });

  test('copia do Firestore so com o token de notificacao nao vale', () {
    // O que o Firestore devolvia ao reabrir sem conexao (29/10/2026).
    expect(
        ApiService.isCompleteProfile({
          'id': 'u1',
          'fcm_tokens': ['tok'],
          'fcm_token_updated_at': '2026-10-29T02:00:00.000',
        }),
        isFalse);
    // O que ficava gravado no aparelho depois disso.
    expect(ApiService.isCompleteProfile({'id': 'u1'}), isFalse);
    expect(ApiService.isCompleteProfile({'id': 'u1', 'name': '  '}), isFalse);
    expect(ApiService.isCompleteProfile(null), isFalse);
  });
}
