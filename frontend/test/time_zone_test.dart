import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/time_zone.dart';

/// Fuso do celular na batida (03/11/2026): o Guilherme em Mato Grosso.
void main() {
  test('manda o offset do momento da batida', () {
    final now = DateTime.now();
    final fields = deviceTimeZoneFields(now);
    expect(fields['utc_offset_minutes'], now.timeZoneOffset.inMinutes);
  });

  test('reenvia o fuso guardado na fila; batida antiga vai sem', () {
    expect(
      storedTimeZoneFields({'utc_offset_minutes': -240, 'time_zone': 'America/Cuiaba'}),
      {'utc_offset_minutes': -240, 'time_zone': 'America/Cuiaba'},
    );
    expect(storedTimeZoneFields({'utc_offset_minutes': -240.0}), {'utc_offset_minutes': -240});
    expect(storedTimeZoneFields({'timestamp': '2026-11-03T07:30:00'}), isEmpty);
    // Nome sem offset nao serve de nada para o servidor.
    expect(storedTimeZoneFields({'time_zone': 'America/Cuiaba'}), isEmpty);
  });

  test('rotulo so para ponto fora de Brasilia', () {
    expect(timeZoneLabel(-240, 'America/Cuiaba'), 'Cuiaba (UTC-4)');
    expect(timeZoneLabel(-300, 'America/Rio_Branco'), 'Rio Branco (UTC-5)');
    expect(timeZoneLabel(-240, null), 'UTC-4');
    expect(timeZoneLabel(-270, null), 'UTC-4:30');
    expect(timeZoneLabel(-180, 'America/Sao_Paulo'), isNull);
    expect(timeZoneLabel(null, 'America/Cuiaba'), isNull);
  });
}
