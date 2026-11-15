import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/screens/punch_pending_screen.dart';

class _FakeSource extends PunchPendingSource {
  @override
  Future<List<Map<String, dynamic>>> users() async => [
        {'id': 'u1', 'name': 'Guilherme', 'role': 'employee'},
        {'id': 'u2', 'name': 'Crysnamurt', 'role': 'employee'},
        {'id': 'u3', 'name': 'Em dia', 'role': 'employee'},
        {'id': 'u4', 'name': 'Diarista', 'role': 'employee', 'daily_mode': true},
        {'id': 'g1', 'name': 'Gestor', 'role': 'manager'},
      ];

  @override
  Future<List<Map<String, dynamic>>> records(DateTime start, DateTime end) async {
    Map<String, dynamic> p(String id, String uid, String type, String ts,
            [Map<String, dynamic> extra = const {}]) =>
        {'id': id, 'user_id': uid, 'record_type': type, 'timestamp': ts, ...extra};
    final full = <Map<String, dynamic>>[];
    // u3 bate certo todos os dias uteis de 09 a 13/11.
    for (final day in [9, 10, 11, 12, 13]) {
      final d = '2026-11-${day.toString().padLeft(2, '0')}';
      full.add(p('u3in$day', 'u3', 'check_in', '${d}T08:00:00'));
      if (day != 13) full.add(p('u3out$day', 'u3', 'check_out', '${d}T17:00:00'));
    }
    return [
      ...full,
      // Guilherme: entrada esquecida (dia seguinte entrou de novo).
      for (final day in [9, 10, 11, 12, 13])
        p('g$day', 'u1', 'check_in', '2026-11-${day.toString().padLeft(2, '0')}T08:00:00'),
      p('gout13', 'u1', 'check_out', '2026-11-13T17:00:00'),
      // Crysnamurt: Esqueci sem horario e pausa solta.
      p('c1', 'u2', 'check_in', '2026-11-10T21:24:42'),
      p('forgot_c1', 'u2', 'check_out', '2026-11-10T21:24:43'),
      p('c2', 'u2', 'break_start', '2026-11-11T03:58:33'),
      p('c3', 'u2', 'check_in', '2026-11-12T08:00:00'),
      p('c4', 'u2', 'check_out', '2026-11-12T17:00:00'),
    ];
  }
}

/// Aba Pendencias (15/11/2026) num celular de 360 px.
void main() {
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: PunchPendingScreen(
        source: _FakeSource(),
        clock: () => DateTime(2026, 11, 13, 20),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('lista quem tem pendencia e conta quem esta em dia',
      (tester) async {
    await open(tester);
    expect(find.text('Guilherme'), findsOneWidget);
    expect(find.text('Crysnamurt'), findsOneWidget);
    // Em dia, diarista e gestor que nao bate nao aparecem.
    expect(find.text('Em dia'), findsNothing);
    expect(find.text('Diarista'), findsNothing);
    expect(find.text('Gestor'), findsNothing);
    expect(find.textContaining('Turno sem saída: 4'), findsWidgets);
    await tester.scrollUntilVisible(
        find.text('1 pessoa sem pendência no período.'), 200);
    await tester.scrollUntilVisible(find.text('Crysnamurt'), -200);

    await tester.tap(find.text('Crysnamurt'));
    await tester.pumpAndSettle();
    expect(
        find.text('Turno de 10/11 21:24 fechado no "Esqueci" (0h): falta '
            'lançar o horário real da saída.'),
        findsOneWidget);
    expect(find.text('Início de pausa às 11/11 03:58 sem turno aberto.'),
        findsOneWidget);
  });
}
