import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ponto_app/services/server_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hora do servidor no ultimo contato (03/11/2026): vai com a batida offline
/// para o servidor conferir o relogio do celular.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ServerClock.resetForTest();
  });

  test('so aceita hora do servidor em UTC', () {
    expect(ServerClock.parseServerTime('2026-11-03T10:00:00.123Z'),
        DateTime.utc(2026, 11, 3, 10, 0, 0, 123));
    expect(ServerClock.parseServerTime('2026-11-03T10:00:00'), isNull);
    expect(ServerClock.parseServerTime('ontem'), isNull);
    expect(ServerClock.parseServerTime(null), isNull);
  });

  test('sem contato com o servidor a batida vai sem ancora', () async {
    expect(await ServerClock.anchorFields(), isEmpty);
  });

  test('cada resposta do backend vira a ancora da proxima batida', () async {
    final client = ServerClockClient(MockClient((request) async =>
        http.Response('{}', 200,
            headers: {'x-server-time': '2026-11-03T10:00:00.000Z'})));
    await client.get(Uri.parse('https://ponto.test/api/me'));

    final fields = await ServerClock.anchorFields();
    expect(fields['server_anchor'], '2026-11-03T10:00:00.000Z');
    final device = DateTime.parse(fields['device_anchor'] as String);
    expect(device.isUtc, isTrue);
    expect(DateTime.now().toUtc().difference(device).inSeconds, lessThan(5));
    // Contato nesta abertura do app: vai o cronometro tambem.
    expect(fields['anchor_elapsed_ms'], isA<int>());

    // Fica guardada para depois de fechar e abrir o app (sem o cronometro).
    final saved = jsonDecode(
        (await SharedPreferences.getInstance()).getString('server_clock_anchor')!);
    expect(saved['server'], '2026-11-03T10:00:00.000Z');
    ServerClock.resetForTest();
    final reopened = await ServerClock.anchorFields();
    expect(reopened['server_anchor'], '2026-11-03T10:00:00.000Z');
    expect(reopened.containsKey('anchor_elapsed_ms'), isFalse);
  });

  test('resposta sem a hora do servidor nao mexe na ancora', () async {
    final client = ServerClockClient(
        MockClient((request) async => http.Response('{}', 200)));
    await client.get(Uri.parse('https://ponto.test/api/me'));
    expect(await ServerClock.anchorFields(), isEmpty);
  });

  test('a fila reenvia a ancora guardada; batida antiga vai sem', () {
    expect(
      ServerClock.storedAnchorFields({
        'server_anchor': '2026-11-03T10:00:00.000Z',
        'device_anchor': '2026-11-03T09:50:00.000Z',
        'anchor_elapsed_ms': 1500.0,
      }),
      {
        'server_anchor': '2026-11-03T10:00:00.000Z',
        'device_anchor': '2026-11-03T09:50:00.000Z',
        'anchor_elapsed_ms': 1500,
      },
    );
    expect(ServerClock.storedAnchorFields({'timestamp': '2026-11-03T07:30:00'}),
        isEmpty);
  });
}
