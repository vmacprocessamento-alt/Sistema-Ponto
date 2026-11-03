import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/punch_review.dart';

/// Aba Conferencia (03/11/2026): o que a Gestao precisa olhar.
void main() {
  const gps = {'latitude': -15.6, 'longitude': -56.1};

  Map<String, dynamic> punch([Map<String, dynamic> extra = const {}]) => {
        'id': 'abc12345',
        'record_type': 'check_in',
        'timestamp': '2026-11-03T07:30:00',
        ...gps,
        ...extra,
      };

  test('batida normal com GPS nao entra', () {
    expect(reviewReasons(punch()), isEmpty);
    expect(reviewReasons(punch({'utc_offset_minutes': -180})), isEmpty);
  });

  test('offline enviada muito depois e de app antigo', () {
    expect(
      reviewReasons(punch({
        'synced_from_offline': true,
        'offline_delay_minutes': 130,
        'offline_without_anchor': true,
      })),
      [
        'Offline de app antigo: relógio do celular sem conferência',
        'Batida offline enviada 2h10 depois',
      ],
    );
    // Poucos minutos sem sinal nao chamam atencao.
    expect(
        reviewReasons(
            punch({'synced_from_offline': true, 'offline_delay_minutes': 12})),
        isEmpty);
    expect(
        reviewReasons(
            punch({'synced_from_offline': true, 'offline_delay_minutes': 1500})),
        ['Batida offline enviada 1 dia e 1h depois']);
  });

  test('relogio do celular diferente do servidor', () {
    expect(reviewReasons(punch({'clock_skew_seconds': -600})),
        ['Relógio do celular 10 min atrasado']);
    expect(reviewReasons(punch({'clock_skew_seconds': 7200})),
        ['Relógio do celular 2h adiantado']);
    expect(reviewReasons(punch({'device_timestamp': '2026-11-03T07:20:00'})),
        ['Hora do celular diferente da registrada (03/11 07:20)']);
    expect(reviewReasons(punch({'device_timestamp': '2026-11-03T07:28:00'})),
        isEmpty);
  });

  test('outro fuso e fuso trocado no meio do turno', () {
    expect(
      reviewReasons(punch({
        'utc_offset_minutes': -240,
        'time_zone': 'America/Cuiaba',
        'device_utc_offset_minutes': -180,
      })),
      [
        'Fuso do celular trocado durante o turno (UTC-3 na batida)',
        'Fora do fuso de Brasília: Cuiaba (UTC-4)',
      ],
    );
    // Pausa e saida seguem o fuso da entrada: so ela avisa.
    expect(
        reviewReasons(punch({
          'record_type': 'check_out',
          'utc_offset_minutes': -240,
          'time_zone': 'America/Cuiaba',
        })),
        isEmpty);
  });

  test('sem GPS', () {
    expect(reviewReasons({'id': 'abc12345', 'timestamp': '2026-11-03T07:30:00'}),
        ['Sem localização (GPS)']);
  });

  test('conferida, do gestor ou do sistema nao entra', () {
    const bad = {'latitude': null, 'offline_without_anchor': true};
    expect(reviewReasons(punch({...bad, 'reviewed_at': '2026-11-03'})), isEmpty);
    expect(reviewReasons(punch({...bad, 'created_by_admin': true})), isEmpty);
    expect(reviewReasons(punch({...bad, 'edited_by_admin': true})), isEmpty);
    expect(reviewReasons(punch({...bad, 'auto_closed': true})), isEmpty);
    expect(reviewReasons(punch({...bad, 'id': 'forgot_abc12345'})), isEmpty);
  });

  test('rotulo da recusa e link do mapa', () {
    expect(rejectionReasonLabel('clock_moved_back'),
        'Hora do celular atrasada depois do último contato');
    expect(rejectionReasonLabel('too_old'), 'Offline com mais de 48 horas');
    expect(rejectionReasonLabel('xyz'), 'Recusada pelo servidor');
    expect(recordMapUri(punch()).toString(),
        'https://www.google.com/maps/search/?api=1&query=-15.6%2C-56.1');
    expect(recordMapUri({'latitude': null}), isNull);
  });
}
