import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/screens/punch_pending_screen.dart';

class _FakeSource extends PunchPendingSource {
  final created = <Map<String, dynamic>>[];
  final edited = <Map<String, dynamic>>[];
  final deleted = <String>[];
  final reviewed = <String>[];

  @override
  Future<String?> createPunch({
    required String userId,
    required String type,
    required DateTime at,
    required String notes,
    String? shiftEntryId,
  }) async {
    created.add({'user': userId, 'type': type, 'at': at, 'notes': notes, 'shift': shiftEntryId});
    return 'novo${created.length}';
  }

  @override
  Future<void> editPunch({
    required String recordId,
    required DateTime at,
    required String reason,
    String? notes,
    String? newType,
  }) async {
    edited.add({'id': recordId, 'at': at, 'reason': reason, 'type': newType});
  }

  @override
  Future<void> deletePunch(String recordId, String reason) async =>
      deleted.add(recordId);

  @override
  Future<void> markReviewed(List<String> ids) async => reviewed.addAll(ids);

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
  Future<_FakeSource> open(WidgetTester tester, {bool admin = true}) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _FakeSource();
    await tester.pumpWidget(MaterialApp(
      home: PunchPendingScreen(
        isAdmin: admin,
        source: source,
        clock: () => DateTime(2026, 11, 13, 20),
      ),
    ));
    await tester.pumpAndSettle();
    return source;
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Fechar turno lanca a saida ligada a entrada', (tester) async {
    final source = await open(tester);
    await tapVisible(tester, find.text('Guilherme'));
    await tapVisible(tester, find.text('Fechar turno').first);
    // Sugestao: 8h depois da entrada de 09/11 08:00, com o motivo pronto.
    expect(find.text('16:00'), findsOneWidget);
    await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Fechar turno'));
    expect(source.created, [
      {
        'user': 'u1',
        'type': 'check_out',
        'at': DateTime(2026, 11, 9, 16),
        'notes': 'Saída não batida; lançada pelo gestor',
        'shift': 'g9',
      },
    ]);
  });

  testWidgets('Lancar saida real do Esqueci edita a propria saida',
      (tester) async {
    final source = await open(tester);
    await tapVisible(tester, find.text('Crysnamurt'));
    await tapVisible(tester, find.text('Lançar saída real'));
    await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Salvar'));
    expect(source.edited.single['id'], 'forgot_c1');
    final at = source.edited.single['at'] as DateTime;
    expect(at.isAfter(DateTime(2026, 11, 10, 21, 24)), isTrue);
    expect(at.isBefore(DateTime(2026, 11, 12, 8)), isTrue);
  });

  testWidgets('dia sem ponto: Lancar ponto cria entrada e saida', (tester) async {
    final source = await open(tester);
    await tapVisible(tester, find.text('Crysnamurt'));
    await tapVisible(tester, find.text('Lançar ponto'));
    await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Lançar'));
    expect([for (final punch in source.created) punch['type']],
        ['check_in', 'check_out']);
    expect(source.created.first['at'], DateTime(2026, 11, 9, 8));
    expect(source.created.last['at'], DateTime(2026, 11, 9, 17));
    expect(source.created.last['shift'], 'novo1');
  });

  testWidgets('gestor fecha turno, mas nao edita nem apaga', (tester) async {
    await open(tester, admin: false);
    await tapVisible(tester, find.text('Crysnamurt'));
    expect(find.text('Lançar saída real'), findsNothing);
    expect(find.text('Apagar'), findsNothing);
    expect(find.text('Lançar ponto'), findsOneWidget);
    await tapVisible(tester, find.text('Guilherme'));
    expect(find.text('Fechar turno'), findsWidgets);
    expect(find.text('Apagar entrada'), findsNothing);
  });

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
