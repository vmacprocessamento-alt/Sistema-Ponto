import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/punch_issues.dart';

/// Aba Pendencias (15/11/2026): o que a equipe deixou de bater.
Map<String, dynamic> _p(String id, String type, String ts,
        [Map<String, dynamic> extra = const {}]) =>
    {'id': id, 'record_type': type, 'timestamp': ts, ...extra};

List<PunchIssueKind> _kinds(List<PunchIssue> issues) =>
    [for (final issue in issues) issue.kind];

void main() {
  // Segunda 09/11/2026 a sexta 13/11/2026; "agora" e sexta 13/11 as 20:00.
  final from = DateTime(2026, 11, 9);
  final now = DateTime(2026, 11, 13, 20);

  List<PunchIssue> issues(List<Map<String, dynamic>> records,
          {bool missing = false}) =>
      findPunchIssues(records,
          from: from, now: now, checkMissingDays: missing);

  test('dia normal nao tem pendencia', () {
    expect(
        issues([
          _p('a', 'check_in', '2026-11-09T08:00:00'),
          _p('b', 'break_start', '2026-11-09T12:00:00'),
          _p('c', 'break_end', '2026-11-09T13:00:00'),
          _p('d', 'check_out', '2026-11-09T17:00:00'),
        ]),
        isEmpty);
  });

  test('entrada sem saida, e outra entrada no dia seguinte', () {
    final found = issues([
      _p('a', 'check_in', '2026-11-09T08:00:00'),
      _p('b', 'check_in', '2026-11-10T08:00:00'),
      _p('c', 'check_out', '2026-11-10T17:00:00'),
    ]);
    expect(_kinds(found), [PunchIssueKind.openShift]);
    expect(found.single.text, 'Entrada de 09/11 08:00 sem saída.');
  });

  test('turno aberto ha mais de 16h e pendencia; o de agora nao', () {
    final old = issues([_p('a', 'check_in', '2026-11-12T21:00:00')]);
    expect(_kinds(old), [PunchIssueKind.openShift]);
    expect(old.single.text, contains('há 23h00'));
    expect(issues([_p('a', 'check_in', '2026-11-13T08:00:00')]), isEmpty);
  });

  test('Esqueci sem o horario real; corrigido nao e pendencia', () {
    final forgot = [
      _p('in1', 'check_in', '2026-11-10T08:00:00'),
      _p('forgot_in1', 'check_out', '2026-11-10T08:00:01'),
    ];
    expect(_kinds(issues(forgot)), [PunchIssueKind.forgottenExit]);
    // O gestor corrigiu a hora na propria saida, ou lancou outra saida.
    expect(
        issues([
          forgot.first,
          _p('forgot_in1', 'check_out', '2026-11-10T17:00:00'),
        ]),
        isEmpty);
    expect(
        issues([
          ...forgot,
          _p('x', 'check_out', '2026-11-10T17:00:00', {'created_by_admin': true, 'batch_real_dates': true}),
        ]),
        isEmpty);
  });

  test('pausa sem retorno: o sistema fechou; retorno batido depois vale', () {
    final auto = [
      _p('a', 'check_in', '2026-11-11T08:00:00'),
      _p('p', 'break_start', '2026-11-11T12:00:00'),
      _p('autoclose_p', 'break_end', '2026-11-11T13:00:00', {'auto_closed': true}),
      _p('d', 'check_out', '2026-11-11T17:00:00'),
    ];
    final found = issues(auto);
    expect(_kinds(found), [PunchIssueKind.autoBreakReturn]);
    expect(found.single.text,
        'Pausa de 11/11 12:00 sem retorno: o sistema fechou com 1h.');
    expect(
        issues([
          ...auto,
          _p('r', 'break_end', '2026-11-11T13:20:00'),
        ]),
        isEmpty);
  });

  test('o caso da Crys antes da correcao: Esqueci e pausa solta no dia seguinte',
      () {
    final found = issues([
      _p('a1', 'check_in', '2026-11-10T08:09:38'),
      _p('a2', 'check_out', '2026-11-10T17:49:51'),
      _p('b1', 'check_in', '2026-11-10T21:24:42'),
      _p('forgot_b1', 'check_out', '2026-11-10T21:24:43'),
      _p('p1', 'break_start', '2026-11-11T03:58:33'),
      _p('p2', 'break_end', '2026-11-11T04:50:25'),
    ]);
    expect(_kinds(found), [
      PunchIssueKind.forgottenExit,
      PunchIssueKind.loosePunch,
      PunchIssueKind.loosePunch,
    ]);
  });

  test('jornada de mais de 16h ligada ao turno', () {
    final found = issues([
      _p('in', 'check_in', '2026-11-10T21:00:00'),
      _p('out', 'check_out', '2026-11-11T17:00:00', {'shift_entry_id': 'in'}),
    ]);
    expect(_kinds(found), [PunchIssueKind.longShift]);
    expect(found.single.text, startsWith('Jornada de 20h00'));
  });

  test('saida sem entrada e solta', () {
    expect(_kinds(issues([_p('o', 'check_out', '2026-11-12T17:00:00')])),
        [PunchIssueKind.loosePunch]);
  });

  test('dias uteis sem ponto, sem fim de semana nem feriado', () {
    // Semana de 16/11 a 20/11/2026: 20/11 e feriado (Consciencia Negra).
    final found = findPunchIssues([
      _p('a', 'check_in', '2026-11-16T08:00:00'),
      _p('b', 'check_out', '2026-11-16T17:00:00'),
    ], from: DateTime(2026, 11, 14), now: DateTime(2026, 11, 23, 9));
    expect([for (final issue in found) issue.at.day], [17, 18, 19]);
    expect(found.first.text, startsWith('17/11: nenhuma batida'));
    // Cadastrada so em 18/11: antes disso nao conta.
    final late = findPunchIssues([], from: DateTime(2026, 11, 14),
        now: DateTime(2026, 11, 23, 9), activeSince: DateTime(2026, 11, 18));
    expect([for (final issue in late) issue.at.day], [18, 19]);
  });

  test('turno da noite conta para o dia seguinte; antes do periodo nao entra',
      () {
    final found = findPunchIssues([
      // Noite de domingo 08/11 ate segunda 09/11 07:00: segunda tem batida.
      _p('a', 'check_in', '2026-11-08T19:00:00'),
      _p('b', 'check_out', '2026-11-09T07:00:00'),
      // Entrada esquecida em 06/11, antes do periodo.
      _p('c', 'check_in', '2026-11-06T08:00:00'),
    ], from: DateTime(2026, 11, 9), now: DateTime(2026, 11, 10, 9));
    expect(found, isEmpty);
  });

  test('dia com o lote antigo do gestor fica de fora', () {
    expect(
        issues([
          _p('o', 'check_out', '2026-11-10T07:00:00', {'created_by_admin': true}),
          _p('i', 'check_in', '2026-11-10T19:30:00', {'created_by_admin': true}),
        ]),
        isEmpty);
  });
}
