import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:ponto_app/screens/month_overview.dart';

/// O mes na Dash: meta e saldo so para o estagiario; quem faz o proprio
/// horario ve so as horas e as extras.
void main() {
  // Quarta, 28/10/2026, ultimo dia do periodo 29/09 a 28/10.
  final hoje = DateTime(2026, 10, 28, 17);

  Map<String, dynamic> dia(String date, double horas,
          {String? entrada, String? saida, double extras = 0}) =>
      {
        'date': date,
        'check_in': entrada,
        'check_out': saida,
        'total_hours': horas,
        'overtime_hours': extras,
        'extra_50': extras,
      };

  final dias = [
    dia('2026-10-13', 11.5, entrada: '08:00', saida: '19:30', extras: 3.5),
    dia('2026-10-14', 6, entrada: '13:30', saida: '19:30'),
    dia('2026-10-27', 4.5, entrada: '08:00', saida: '12:30'),
  ];

  setUpAll(() => initializeDateFormatting('pt_BR'));

  setUp(() {
    MonthOverview.debugNow = () => hoje;
    MonthOverview.debugLoader = (start, end) async => {
          'daily_records': dias,
          'summary': {
            'total_hours': '22.0',
            'total_extras': '0',
            'total_50': '3.5',
            'total_100': '0',
          },
        };
  });

  tearDown(() {
    MonthOverview.debugNow = null;
    MonthOverview.debugLoader = null;
  });

  Future<void> abrir(WidgetTester tester, Map<String, dynamic> user) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: MonthOverview(user: user)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  bool temTexto(String trecho) => find
      .byWidgetPredicate((w) =>
          (w is Text && (w.data ?? w.textSpan?.toPlainText() ?? '').contains(trecho)) ||
          (w is RichText && w.text.toPlainText().contains(trecho)))
      .evaluate()
      .isNotEmpty;

  testWidgets('quem faz o proprio horario nao ve meta nem falta',
      (tester) async {
    await abrir(tester, {'id': 'u1', 'role': 'employee', 'job_title': 'Operador'});

    expect(temTexto('HORAS NO MÊS'), isTrue);
    expect(temTexto('22h 00m'), isTrue);
    expect(temTexto('Horas extras'), isTrue);
    expect(temTexto('50%: 3h 30m'), isTrue);
    for (final proibido in ['meta', 'falta', 'abaixo', 'Faltam', 'SALDO', 'esperad']) {
      expect(temTexto(proibido), isFalse, reason: 'apareceu "$proibido"');
    }
  });

  testWidgets('estagiario ve o saldo e as faltas', (tester) async {
    await abrir(tester, {'id': 'u2', 'role': 'intern', 'daily_hours': 6});

    expect(temTexto('SEU SALDO ATÉ ONTEM'), isTrue);
    expect(temTexto('falta'), isTrue);
    expect(temTexto('HORAS NO MÊS'), isFalse);
  });

  testWidgets('cargo "Estagiario" com papel de funcionario conta como estagiario',
      (tester) async {
    await abrir(tester, {'id': 'u3', 'role': 'employee', 'job_title': 'Estagiário'});
    expect(temTexto('SEU SALDO ATÉ ONTEM'), isTrue);
  });

  testWidgets('tocar no dia mostra os horarios dele', (tester) async {
    await abrir(tester, {'id': 'u1', 'role': 'employee'});

    await tester.tap(find.text('11h30'));
    await tester.pumpAndSettle();

    expect(temTexto('Terça-feira, 13/10'), isTrue);
    expect(temTexto('Trabalhou: 08:00 – 19:30'), isTrue);
    expect(temTexto('Horas extras neste dia: 3h 30m'), isTrue);
  });

  testWidgets('hoje vem atualizado pela Dash', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MonthOverview(
            user: const {'id': 'u1', 'role': 'employee'},
            todayRecord: dia('2026-10-28', 2, entrada: '08:00'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Hoje (selecionado ao abrir): turno aberto desde as 08:00.
    expect(temTexto('Trabalhou: 08:00 – agora'), isTrue);
    expect(temTexto('24h 00m'), isTrue); // 22h do mes + 2h de hoje
  });

  testWidgets('operador ve a composicao sem "fora do horario"',
      (tester) async {
    await abrir(tester, {'id': 'u1', 'role': 'employee', 'job_title': 'Operador'});

    expect(temTexto('COMPOSIÇÃO DAS HORAS'), isTrue);
    expect(temTexto('Toda hora trabalhada conta'), isTrue);
    expect(temTexto('Extra 50%'), isTrue);
    expect(temTexto('Fora do horário'), isFalse);
    expect(temTexto('DIAS TRABALHADOS'), isTrue);
    expect(temTexto('DESTAQUES'), isTrue);
    expect(temTexto('13/10 · 11h 30m'), isTrue); // dia mais longo
  });

  testWidgets('estagiario ve as horas fora do horario na composicao',
      (tester) async {
    await abrir(tester, {'id': 'u2', 'role': 'intern', 'daily_hours': 6});

    expect(temTexto('Fora do horário'), isTrue);
    expect(temTexto('só com liberação do gestor'), isTrue);
  });
}
