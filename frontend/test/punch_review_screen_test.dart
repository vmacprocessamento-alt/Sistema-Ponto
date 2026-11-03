import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/screens/punch_review_screen.dart';

class _FakeSource extends PunchReviewSource {
  _FakeSource(this.items, this.refused);

  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> refused;
  final reviewed = <String>[];

  @override
  Future<Map<String, String>> names() async =>
      {'u1': 'Guilherme', 'u2': 'Crysnamurt'};

  @override
  Future<List<Map<String, dynamic>>> records(DateTime start, DateTime end) async =>
      items;

  @override
  Future<List<Map<String, dynamic>>> rejections(int days) async => refused;

  @override
  Future<int> review(List<String> ids) async {
    reviewed.addAll(ids);
    return ids.length;
  }
}

/// Aba Conferencia (03/11/2026) num celular de 360 px.
void main() {
  final today = DateTime.now();
  String at(int hour) =>
      DateTime(today.year, today.month, today.day, hour).toIso8601String();

  Future<_FakeSource> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _FakeSource([
      {
        'id': 'off00001', 'user_id': 'u1', 'record_type': 'check_in',
        'timestamp': at(7), 'synced_from_offline': true,
        'offline_delay_minutes': 190, 'clock_skew_seconds': -900,
        'utc_offset_minutes': -240, 'time_zone': 'America/Cuiaba',
        'latitude': -15.6, 'longitude': -56.1,
      },
      {
        'id': 'nogps001', 'user_id': 'u2', 'record_type': 'check_out',
        'timestamp': at(17),
      },
      // Normal: nao aparece.
      {
        'id': 'ok000001', 'user_id': 'u2', 'record_type': 'check_in',
        'timestamp': at(8), 'latitude': -23.5, 'longitude': -46.6,
      },
    ], [
      {
        'user_id': 'u1', 'user_name': 'Guilherme', 'record_type': 'check_in',
        'reason': 'clock_moved_back', 'device_timestamp': at(6),
        'offline': true, 'created_at_local': at(9),
      },
    ]);
    await tester.pumpWidget(
        MaterialApp(home: PunchReviewScreen(source: source)));
    await tester.pumpAndSettle();
    return source;
  }

  testWidgets('mostra o que conferir e as recusadas', (tester) async {
    await open(tester);
    expect(find.text('Para conferir (2)'), findsOneWidget);
    expect(find.text('Tentativas recusadas (1)'), findsOneWidget);
    expect(find.text('Batida offline enviada 3h10 depois'), findsOneWidget);
    expect(find.text('Relógio do celular 15 min atrasado'), findsOneWidget);
    expect(find.text('Fora do fuso de Brasília: Cuiaba (UTC-4)'), findsOneWidget);
    expect(find.text('Sem localização (GPS)'), findsOneWidget);
    // Mapa so para quem tem GPS.
    expect(find.text('Ver no mapa'), findsOneWidget);

    await tester.tap(find.text('Tentativas recusadas (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hora do celular atrasada depois do último contato'),
        findsOneWidget);
  });

  testWidgets('Conferido tira a batida da lista', (tester) async {
    final source = await open(tester);
    await tester.ensureVisible(find.text('Conferido').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Conferido').first);
    await tester.pumpAndSettle();
    expect(source.reviewed, ['off00001']);
    expect(find.text('Para conferir (1)'), findsOneWidget);
    expect(find.text('Batida offline enviada 3h10 depois'), findsNothing);
  });

  testWidgets('Marcar todas pede confirmacao', (tester) async {
    final source = await open(tester);
    await tester.tap(find.text('Marcar todas'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Marcar todas'));
    await tester.pumpAndSettle();
    expect(source.reviewed, ['off00001', 'nogps001']);
    expect(find.text('Nada para conferir no período.'), findsOneWidget);
  });
}
