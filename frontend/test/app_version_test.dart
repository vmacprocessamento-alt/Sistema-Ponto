import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/services/app_version.dart';

/// "Versao do app" no Perfil e no login: data e hora do deploy e o commit.
void main() {
  test('carimbo do deploy vira data, hora e commit', () {
    expect(appVersionLabel('b27c4cb-20261029143205'), '29/10/2026 14:32 (b27c4cb)');
  });

  test('build feito a mao, sem carimbo', () {
    expect(appVersionLabel(''), 'build local');
    expect(appVersionLabel('  '), 'build local');
  });

  test('carimbo em outro formato aparece como veio', () {
    expect(appVersionLabel('teste-1'), 'teste-1');
  });
}
