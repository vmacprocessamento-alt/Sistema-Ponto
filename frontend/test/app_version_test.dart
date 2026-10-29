import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/services/app_version.dart';
import 'package:ponto_app/utils/device_label.dart';

/// Versao no Perfil e no login: o numero que sobe a cada deploy.
void main() {
  test('numero do deploy', () {
    expect(appVersionLabel('0.3'), 'Versão 0.3');
    expect(appVersionLabel(' 1.12 '), 'Versão 1.12');
  });

  test('build feito a mao, sem numero', () {
    expect(appVersionLabel(''), 'Versão de teste');
  });

  group('Gestao: app desatualizado', () {
    test('versao menor que a do gestor', () {
      expect(isOutdatedAppVersion('0.3', '0.4'), isTrue);
      expect(isOutdatedAppVersion('0.9', '1.0'), isTrue);
      // 0.10 vem depois de 0.9 (numero, nao texto).
      expect(isOutdatedAppVersion('0.9', '0.10'), isTrue);
    });

    test('mesma versao ou mais nova nao e desatualizada', () {
      expect(isOutdatedAppVersion('0.4', '0.4'), isFalse);
      expect(isOutdatedAppVersion('0.10', '0.9'), isFalse);
    });

    test('sem registro conta como desatualizado', () {
      expect(isOutdatedAppVersion(null, '0.4'), isTrue);
      expect(isOutdatedAppVersion('', '0.4'), isTrue);
    });

    test('build de teste nao entra na conta', () {
      expect(isOutdatedAppVersion('teste', '0.4'), isFalse);
      expect(isOutdatedAppVersion('0.1', ''), isFalse);
      expect(hasNumberedAppVersion(''), isFalse);
      expect(hasNumberedAppVersion('0.4'), isTrue);
    });
  });

  group('aparelho', () {
    const iphone =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15';
    const android =
        'Mozilla/5.0 (Linux; Android 14; SM-A155M) AppleWebKit/537.36 Chrome/130.0 Mobile';
    const windows =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0';
    const mac =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15';

    test('tipo de aparelho e se abriu pelo icone', () {
      expect(describeDevice(iphone, installed: true), 'iPhone · app instalado');
      expect(describeDevice(android), 'Android · navegador');
      expect(describeDevice(windows), 'Computador · navegador');
      expect(describeDevice(mac), 'Computador · navegador');
      // iPad recente se apresenta como Mac, mas tem tela de toque.
      expect(describeDevice(mac, maxTouchPoints: 5), 'iPad · navegador');
      expect(describeDevice(''), 'Aparelho desconhecido · navegador');
    });
  });
}
