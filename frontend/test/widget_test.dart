import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/services/app_config.dart';

void main() {
  test('o backend fica no mesmo site, em /api', () {
    expect(
      AppConfig.resolveBackendUrl('', Uri.parse('https://ponto.vmacengenharia.com/?k=1')),
      'https://ponto.vmacengenharia.com/api',
    );
  });

  test('API_BASE_URL troca o endereco (testes locais)', () {
    expect(
      AppConfig.resolveBackendUrl('http://127.0.0.1:8000/', Uri.parse('http://127.0.0.1:5005/')),
      'http://127.0.0.1:8000',
    );
  });
}
