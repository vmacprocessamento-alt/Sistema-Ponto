import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/services/app_version.dart';

/// Versao no Perfil e no login: o numero que sobe a cada deploy.
void main() {
  test('numero do deploy', () {
    expect(appVersionLabel('0.3'), 'Versão 0.3');
    expect(appVersionLabel(' 1.12 '), 'Versão 1.12');
  });

  test('build feito a mao, sem numero', () {
    expect(appVersionLabel(''), 'Versão de teste');
  });
}
