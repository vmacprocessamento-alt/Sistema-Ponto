import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/shift_records.dart';
import 'package:ponto_app/utils/timesheet.dart';

Map<String, dynamic> _punch(String id, String type, String timestamp) =>
    {'id': id, 'record_type': type, 'timestamp': timestamp};

// Ponto lancado pelo gestor no lote ANTIGO (todos os horarios na data
// escolhida).
Map<String, dynamic> _manual(String id, String type, String timestamp) =>
    {..._punch(id, type, timestamp), 'created_by_admin': true};

// Ponto do lote novo: data real e batch_real_dates.
Map<String, dynamic> _batch(String id, String type, String timestamp) =>
    {..._manual(id, type, timestamp), 'batch_real_dates': true};

// Dias de trabalho dos pontos, ja calculados (groupRecordsByWorkDay).
Map<String, Map<String, dynamic>> _workDays(
        List<Map<String, dynamic>> records) =>
    {
      for (final entry in groupRecordsByWorkDay(records).entries)
        entry.key: _day(entry.key, entry.value),
    };

Map<String, dynamic> _day(String date, List<Map<String, dynamic>> records,
        {String role = 'employee'}) =>
    computeWorkDay(date, records, role);

void _expectHours(
  Map<String, dynamic> day, {
  required double total,
  double regular = 0,
  double extra50 = 0,
  double extra100 = 0,
}) {
  expect(day['total_hours'], closeTo(total, 1e-9), reason: 'total_hours');
  expect(day['regular_hours'], closeTo(regular, 1e-9), reason: 'regular_hours');
  expect(day['extra_50'], closeTo(extra50, 1e-9), reason: 'extra_50');
  expect(day['extra_100'], closeTo(extra100, 1e-9), reason: 'extra_100');
  expect(day['overtime_hours'], closeTo(total - regular, 1e-9),
      reason: 'overtime_hours');
}

List<String?> _columns(Map<String, dynamic> day) => [
      day['check_in'],
      day['check_out'],
      day['break_start'],
      day['break_end'],
      day['entry_3'],
      day['exit_3'],
    ];

void main() {
  group('roundPunchTime', () {
    test('arredonda para a meia hora', () {
      expect(roundPunchTime(DateTime(2026, 10, 15, 8, 15, 59)),
          DateTime(2026, 10, 15, 8));
      expect(roundPunchTime(DateTime(2026, 10, 15, 8, 16)),
          DateTime(2026, 10, 15, 8, 30));
      expect(roundPunchTime(DateTime(2026, 10, 15, 8, 46)),
          DateTime(2026, 10, 15, 9));
      expect(roundPunchTime(DateTime(2026, 10, 15, 23, 50)),
          DateTime(2026, 10, 16));
    });
  });

  group('isHoliday', () {
    test('Consciencia Negra e feriado so a partir de 2024', () {
      expect(isHoliday(DateTime(2026, 11, 20)), isTrue);
      expect(isHoliday(DateTime(2024, 11, 20)), isTrue);
      expect(isHoliday(DateTime(2023, 11, 20)), isFalse);
    });

    test('fixos e Sexta-feira Santa continuam', () {
      expect(isHoliday(DateTime(2026, 10, 12)), isTrue);
      expect(isHoliday(DateTime(2026, 4, 3)), isTrue); // Pascoa 05/04/2026
      expect(isHoliday(DateTime(2026, 10, 15)), isFalse);
    });
  });

  group('computeWorkDay', () {
    test('dia comum 08-17 com almoco registrado = 8h normais', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:02:10.000'),
        _punch('b1', 'break_start', '2026-10-15T12:00:00.000'),
        _punch('b2', 'break_end', '2026-10-15T13:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:05:00.000'),
      ]);
      expect(day['date'], '2026-10-15');
      expect(_columns(day), ['08:00', '12:00', '13:00', '17:00', null, null]);
      _expectHours(day, total: 8, regular: 8);
    });

    test('dia comum 08-17 sem almoco registrado desconta 12-13', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', '12:00', '13:00', '17:00', null, null]);
      _expectHours(day, total: 8, regular: 8);
    });

    test('operador quinta 19:30 ate sexta 07:00 = 10,5h', () {
      final records = [
        _punch('in', 'check_in', '2026-10-15T19:30:12.345'),
        _punch('out', 'check_out', '2026-10-16T07:00:40.000'),
      ];
      final grouped = groupRecordsByWorkDay(records);
      expect(grouped.keys, ['2026-10-15']);
      final day = _day('2026-10-15', grouped['2026-10-15']!);
      // Jantar automatico 20-21; 22h-05h e noturno (100%).
      expect(_columns(day), ['19:30', '20:00', '21:00', '07:00', null, null]);
      _expectHours(day, total: 10.5, regular: 3.5, extra100: 7);
    });

    test('saida do "Esqueci" (1s depois da entrada) nao soma horas', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T19:30:12.345'),
        _punch('forgot_in', 'check_out', '2026-10-15T19:30:13.345'),
      ]);
      expect(_columns(day), ['19:30', null, null, null, null, null]);
      _expectHours(day, total: 0);

      // Sem arredondar antes: 08:15:59 e 08:16:00 virariam 08:00-08:30.
      final edge = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:15:59.500'),
        _punch('forgot_in', 'check_out', '2026-10-15T08:16:00.500'),
      ]);
      expect(edge['check_in'], '08:00');
      expect(edge['check_out'], isNull);
      _expectHours(edge, total: 0);
    });

    test('gestor lanca so a saida real de um turno fechado no "Esqueci"', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:05.000'),
        _punch('forgot_in', 'check_out', '2026-10-15T08:00:06.000'),
        _manual('real', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', '12:00', '13:00', '17:00', null, null]);
      _expectHours(day, total: 8, regular: 8);
    });

    test('noite do lote do gestor com pausa 02:00-03:00 = 10,5h', () {
      // A pausa batida e a refeicao da noite: nao desconta o jantar 20-21.
      final records = [
        _manual('out', 'check_out', '2026-10-15T07:00:00.000'),
        _manual('b1', 'break_start', '2026-10-15T02:00:00.000'),
        _manual('b2', 'break_end', '2026-10-15T03:00:00.000'),
        _manual('in', 'check_in', '2026-10-15T19:30:00.000'),
      ];
      final grouped = groupRecordsByWorkDay(records);
      expect(grouped.keys, ['2026-10-15']);
      final day = _day('2026-10-15', grouped['2026-10-15']!);
      expect(day['check_in'], '19:30');
      expect(_columns(day), ['19:30', '02:00', '03:00', '07:00', null, null]);
      _expectHours(day, total: 10.5, regular: 4.5, extra100: 6);
    });

    test('noite com a unica pausa batida como Pausa 1 = 10,5h', () {
      final records = [
        _punch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('b1', 'break_start', '2026-10-16T00:00:00.000'),
        _punch('b2', 'break_end', '2026-10-16T01:00:00.000'),
        _punch('out', 'check_out', '2026-10-16T07:00:00.000'),
      ];
      final day =
          _day('2026-10-15', groupRecordsByWorkDay(records)['2026-10-15']!);
      expect(_columns(day), ['19:30', '00:00', '01:00', '07:00', null, null]);
      _expectHours(day, total: 10.5, regular: 4.5, extra100: 6);
    });

    test('pausa batida vale pela janela mais proxima, a outra e automatica',
        () {
      // 08-22 cobre almoco e jantar; a Pausa 1 das 19-20 e o jantar.
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('b1', 'break_start', '2026-10-15T19:00:00.000'),
        _punch('b2', 'break_end', '2026-10-15T20:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T22:00:00.000'),
      ]);
      expect(_columns(day),
          ['08:00', '12:00', '13:00', '19:00', '20:00', '22:00']);
      _expectHours(day, total: 12, regular: 12);
    });

    test('noite fechada no "Esqueci": a saida real da manha seguinte vale', () {
      final records = [
        _punch('in', 'check_in', '2026-10-14T19:30:12.345'),
        _punch('forgot_in', 'check_out', '2026-10-14T19:30:13.345'),
        _manual('real', 'check_out', '2026-10-15T07:00:00.000'),
      ];
      final grouped = groupRecordsByWorkDay(records);
      expect(grouped.keys, ['2026-10-14']);
      final day = _day('2026-10-14', grouped['2026-10-14']!);
      expect(_columns(day), ['19:30', '20:00', '21:00', '07:00', null, null]);
      _expectHours(day, total: 10.5, regular: 3.5, extra100: 7);
    });

    test('noite do app na vespera e noite do lote no dia seguinte', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in14', 'check_in', '2026-10-14T19:30:00.000'),
        _manual('out15', 'check_out', '2026-10-15T07:00:00.000'),
        _punch('out14', 'check_out', '2026-10-15T07:00:20.000'),
        _manual('in15', 'check_in', '2026-10-15T19:30:00.000'),
      ]);
      _expectHours(_day('2026-10-14', grouped['2026-10-14']!),
          total: 10.5, regular: 3.5, extra100: 7);
      _expectHours(_day('2026-10-15', grouped['2026-10-15']!),
          total: 10.5, regular: 3.5, extra100: 7);
    });

    test('pausa da noite do lote antes da saida do app da vespera', () {
      // Noite do app 14/10 19:30-07:00 sem pausa e noite do lote antigo em
      // 15/10 (16:50-07:25, Pausa 1 22:00-23:00 e Pausa 2 03:00-03:30, tudo
      // em 15/10). A Pausa 2 fica antes da saida do app, mas e da noite do
      // lote: na noite do app ela tirava o jantar e sumia da outra (24,5h).
      final days = _workDays([
        _punch('in14', 'check_in', '2026-10-14T19:30:00.000'),
        _manual('j1', 'entry_3', '2026-10-15T03:00:00.000'),
        _manual('j2', 'exit_3', '2026-10-15T03:30:00.000'),
        _punch('out14', 'check_out', '2026-10-15T07:00:20.000'),
        _manual('nout', 'check_out', '2026-10-15T07:25:00.000'),
        _manual('nin', 'check_in', '2026-10-15T16:50:00.000'),
        _manual('p1', 'break_start', '2026-10-15T22:00:00.000'),
        _manual('p2', 'break_end', '2026-10-15T23:00:00.000'),
      ]);
      _expectHours(days['2026-10-14']!, total: 10.5, regular: 3.5, extra100: 7);
      expect(_columns(days['2026-10-15']!),
          ['17:00', '22:00', '23:00', '03:00', '03:30', '07:30']);
      _expectHours(days['2026-10-15']!,
          total: 13, regular: 7.5, extra100: 5.5);
    });

    test('noite do lote do gestor com Pausa 2 23:00-00:00 = 10,5h', () {
      final day = _day('2026-10-15', [
        _manual('out', 'check_out', '2026-10-15T07:00:00.000'),
        _manual('in', 'check_in', '2026-10-15T19:30:00.000'),
        _manual('j1', 'entry_3', '2026-10-15T23:00:00.000'),
        _manual('j2', 'exit_3', '2026-10-15T00:00:00.000'),
      ]);
      expect(_columns(day), ['19:30', '23:00', '00:00', '07:00', null, null]);
      _expectHours(day, total: 10.5, regular: 4.5, extra100: 6);
    });

    test('dois turnos 08-11 e 14-18 = 7h, sem pagar o intervalo', () {
      final day = _day('2026-10-15', [
        _punch('in1', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out1', 'check_out', '2026-10-15T11:00:00.000'),
        _punch('in2', 'check_in', '2026-10-15T14:00:00.000'),
        _punch('out2', 'check_out', '2026-10-15T18:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', '11:00', '14:00', '18:00', null, null]);
      _expectHours(day, total: 7, regular: 7);
    });

    test('almoco batido como saida e entrada nao desconta o automatico', () {
      Map<String, dynamic> twoShifts(String out1, String in2, String out2) =>
          _day('2026-10-15', [
            _punch('in1', 'check_in', '2026-10-15T07:00:00.000'),
            _punch('out1', 'check_out', '2026-10-15T$out1:00.000'),
            _punch('in2', 'check_in', '2026-10-15T$in2:00.000'),
            _punch('out2', 'check_out', '2026-10-15T$out2:00.000'),
          ]);

      // 07-11 e 12-17: o intervalo encosta no 12-13.
      final touching = twoShifts('11:00', '12:00', '17:00');
      expect(
          _columns(touching), ['07:00', '11:00', '12:00', '17:00', null, null]);
      _expectHours(touching, total: 9, regular: 9);

      // 07-13 e 14-18: o primeiro turno cobre o 12-13, o intervalo e depois.
      final after = twoShifts('13:00', '14:00', '18:00');
      _expectHours(after, total: 10, regular: 10);

      // 07-11 e 11:30-16: almoco de 30 min fora da janela.
      final short = twoShifts('11:00', '11:30', '16:00');
      expect(_columns(short), ['07:00', '11:00', '11:30', '16:00', null, null]);
      _expectHours(short, total: 8.5, regular: 8.5);
    });

    test('intervalo entre turnos e uma refeicao so', () {
      // 08-13 e 14-22: o intervalo 13-14 e o almoco; o jantar 20-21 do
      // segundo turno continua automatico.
      final day = _day('2026-10-15', [
        _punch('in1', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out1', 'check_out', '2026-10-15T13:00:00.000'),
        _punch('in2', 'check_in', '2026-10-15T14:00:00.000'),
        _punch('out2', 'check_out', '2026-10-15T22:00:00.000'),
      ]);
      expect(_columns(day),
          ['08:00', '13:00', '14:00', '20:00', '21:00', '22:00']);
      _expectHours(day, total: 12, regular: 12);
    });

    test('almoco entre turnos nao cancela o jantar, nem o contrario', () {
      Map<String, dynamic> twoShifts(String date, String in1, String out1,
              String in2, String out2) =>
          _day(date, [
            _punch('in1', 'check_in', '${date}T$in1:00.000'),
            _punch('out1', 'check_out', '${date}T$out1:00.000'),
            _punch('in2', 'check_in', '${date}T$in2:00.000'),
            _punch('out2', 'check_out', '${date}T$out2:00.000'),
          ]);

      // O intervalo 12-13 e o almoco; o jantar 20-21 continua automatico,
      // como no turno unico 07-22 com Pausa 1 12-13.
      final lunch = twoShifts('2026-10-15', '07:00', '12:00', '13:00', '22:00');
      expect(_columns(lunch),
          ['07:00', '12:00', '13:00', '20:00', '21:00', '22:00']);
      _expectHours(lunch, total: 13, regular: 13);

      final rounded =
          twoShifts('2026-10-15', '08:02', '12:01', '13:03', '21:05');
      _expectHours(rounded, total: 11, regular: 11);

      // O intervalo 20-21 e o jantar; o almoco 12-13 continua automatico.
      final dinner = twoShifts('2026-10-15', '08:00', '20:00', '21:00', '23:00');
      expect(_columns(dinner),
          ['08:00', '12:00', '13:00', '20:00', '21:00', '23:00']);
      _expectHours(dinner, total: 13, regular: 12, extra100: 1);

      final saturday =
          twoShifts('2026-10-17', '08:00', '12:00', '13:00', '22:00');
      _expectHours(saturday, total: 12, extra50: 12);
    });

    test('pausa batida na janela que o turno nao cobre nao tira o jantar',
        () {
      // 12:30-22:00 nao cobre o almoco inteiro: a Pausa 1 13-14 e o almoco,
      // o jantar 20-21 continua automatico.
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T12:30:00.000'),
        _punch('b1', 'break_start', '2026-10-15T13:00:00.000'),
        _punch('b2', 'break_end', '2026-10-15T14:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T22:00:00.000'),
      ]);
      expect(_columns(day),
          ['12:30', '13:00', '14:00', '20:00', '21:00', '22:00']);
      _expectHours(day, total: 7.5, regular: 7.5);
    });

    test('noite do lote na data de um turno do app: a noite vale inteira', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in1', 'check_in', '2026-10-15T08:01:00.000'),
        _punch('out1', 'check_out', '2026-10-15T17:02:00.000'),
        _manual('nout', 'check_out', '2026-10-15T07:00:00.000'),
        _manual('nin', 'check_in', '2026-10-15T19:30:00.000'),
      ]);
      expect(grouped.keys, ['2026-10-15']);
      final day = _day('2026-10-15', grouped['2026-10-15']!);
      // Igual a dobra batida no app ("mais de 3 sessoes").
      expect(_columns(day),
          ['08:00', '17:00', '19:30', '20:00', '21:00', '07:00']);
      _expectHours(day, total: 19.5, regular: 12.5, extra100: 7);
    });

    test('dobra inteira no lote: a saida 17:00 nao vira a saida da noite', () {
      final day = _day('2026-10-15', [
        _manual('in1', 'check_in', '2026-10-15T08:00:00.000'),
        _manual('out1', 'check_out', '2026-10-15T17:00:00.000'),
        _manual('nin', 'check_in', '2026-10-15T19:30:00.000'),
        _manual('nout', 'check_out', '2026-10-15T07:00:00.000'),
      ]);
      expect(_columns(day),
          ['08:00', '17:00', '19:30', '20:00', '21:00', '07:00']);
      _expectHours(day, total: 19.5, regular: 12.5, extra100: 7);

      // Com almoco e a pausa da madrugada da noite no mesmo lote.
      final withPauses = _day('2026-10-15', [
        _manual('in1', 'check_in', '2026-10-15T08:00:00.000'),
        _manual('l1', 'break_start', '2026-10-15T12:00:00.000'),
        _manual('l2', 'break_end', '2026-10-15T13:00:00.000'),
        _manual('out1', 'check_out', '2026-10-15T17:00:00.000'),
        _manual('nin', 'check_in', '2026-10-15T19:30:00.000'),
        _manual('p1', 'break_start', '2026-10-15T02:00:00.000'),
        _manual('p2', 'break_end', '2026-10-15T03:00:00.000'),
        _manual('nout', 'check_out', '2026-10-15T07:00:00.000'),
      ]);
      expect(_columns(withPauses),
          ['08:00', '17:00', '19:30', '02:00', '03:00', '07:00']);
      _expectHours(withPauses, total: 19.5, regular: 13.5, extra100: 6);
    });

    test('dobra com o dia antes da saida da noite: a noite vale inteira', () {
      // Quarta 14/10: 06:50-16:00 do app e a noite 19:00-07:00 do lote. A
      // saida 07:00 da noite vem depois da entrada 06:50.
      final records = [
        _punch('in1', 'check_in', '2026-10-14T06:50:00.000'),
        _manual('nout', 'check_out', '2026-10-14T07:00:00.000'),
        _punch('out1', 'check_out', '2026-10-14T16:00:00.000'),
        _manual('nin', 'check_in', '2026-10-14T19:00:00.000'),
      ];
      final grouped = groupRecordsByWorkDay(records);
      expect(grouped.keys, ['2026-10-14']);
      final day = _day('2026-10-14', grouped['2026-10-14']!);
      // 4 sessoes: o almoco 12-13 junta para caber nas 3 colunas.
      expect(_columns(day),
          ['07:00', '16:00', '19:00', '20:00', '21:00', '07:00']);
      _expectHours(day, total: 20, regular: 13, extra100: 7);
      expect(openShiftCheckIn(records), isNull);

      // Tudo no lote: 06-15 e 19-07.
      final batch = _day('2026-10-14', [
        _manual('in1', 'check_in', '2026-10-14T06:00:00.000'),
        _manual('out1', 'check_out', '2026-10-14T15:00:00.000'),
        _manual('nin', 'check_in', '2026-10-14T19:00:00.000'),
        _manual('nout', 'check_out', '2026-10-14T07:00:00.000'),
      ]);
      expect(_columns(batch),
          ['06:00', '15:00', '19:00', '20:00', '21:00', '07:00']);
      _expectHours(batch, total: 20, regular: 13, extra100: 7);

      // 07-16 e 19-07: entrada e saida da noite no mesmo minuto, nas duas
      // ordens possiveis.
      for (final sameMinute in [
        [
          _manual('in1', 'check_in', '2026-10-14T07:00:00.000'),
          _manual('nout', 'check_out', '2026-10-14T07:00:00.000'),
        ],
        [
          _manual('nout', 'check_out', '2026-10-14T07:00:00.000'),
          _manual('in1', 'check_in', '2026-10-14T07:00:00.000'),
        ],
      ]) {
        final tie = _day('2026-10-14', [
          ...sameMinute,
          _manual('out1', 'check_out', '2026-10-14T16:00:00.000'),
          _manual('nin', 'check_in', '2026-10-14T19:00:00.000'),
        ]);
        expect(_columns(tie),
            ['07:00', '16:00', '19:00', '20:00', '21:00', '07:00']);
        _expectHours(tie, total: 20, regular: 13, extra100: 7);
      }
    });

    test('entrada do gestor na manha da correcao do "Esqueci" fica aberta', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in15', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('forgot_in15', 'check_out', '2026-10-15T19:30:01.000'),
        _manual('fix', 'check_out', '2026-10-16T07:00:00.000'),
        _manual('in16', 'check_in', '2026-10-16T08:00:00.000'),
      ]);
      _expectHours(_day('2026-10-15', grouped['2026-10-15']!),
          total: 10.5, regular: 3.5, extra100: 7);
      final open = _day('2026-10-16', grouped['2026-10-16']!);
      expect(_columns(open), ['08:00', null, null, null, null, null]);
      _expectHours(open, total: 0);
    });

    test('refeicao da noite batida como saida e entrada depois da meia-noite',
        () {
      Map<String, Map<String, dynamic>> night(String out1, String in2) {
        final grouped = groupRecordsByWorkDay([
          _punch('in1', 'check_in', '2026-10-14T19:30:00.000'),
          _punch('out1', 'check_out', '$out1:00.000'),
          _punch('in2', 'check_in', '$in2:00.000'),
          _punch('out2', 'check_out', '2026-10-15T07:00:00.000'),
        ]);
        return {
          for (final entry in grouped.entries)
            entry.key: _day(entry.key, entry.value),
        };
      }

      // Saida 00:00 e volta 01:00: uma linha, sem o jantar automatico.
      final midnight = night('2026-10-15T00:00', '2026-10-15T01:00');
      expect(midnight.keys, ['2026-10-14']);
      expect(_columns(midnight['2026-10-14']!),
          ['19:30', '00:00', '01:00', '07:00', null, null]);
      _expectHours(midnight['2026-10-14']!,
          total: 10.5, regular: 4.5, extra100: 6);

      // Saida 23:30 e volta 00:30.
      final before = night('2026-10-14T23:30', '2026-10-15T00:30');
      expect(before.keys, ['2026-10-14']);
      _expectHours(before['2026-10-14']!,
          total: 10.5, regular: 4.5, extra100: 6);

      // Igual a refeicao batida antes da meia-noite (22:30-23:30).
      final sameDay = night('2026-10-14T22:30', '2026-10-14T23:30');
      _expectHours(sameDay['2026-10-14']!,
          total: 10.5, regular: 4.5, extra100: 6);
    });

    test('saida do gestor para o "Esqueci" e noite do lote na mesma data', () {
      // 16/10: uma saida fecha o turno de 15/10, a outra e da noite de 16/10.
      // A da noite e a mais perto da entrada dela; a anterior fecha a vespera.
      final grouped = groupRecordsByWorkDay([
        _punch('in15', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('forgot_in15', 'check_out', '2026-10-15T19:30:06.000'),
        _manual('fix', 'check_out', '2026-10-16T06:00:00.000'),
        _manual('nout', 'check_out', '2026-10-16T07:00:00.000'),
        _manual('nin', 'check_in', '2026-10-16T19:30:00.000'),
      ]);
      _expectHours(_day('2026-10-15', grouped['2026-10-15']!),
          total: 9.5, regular: 2.5, extra100: 7);
      // Sexta 19:30 ate sabado 07:00: 05-07 de sabado a 50%.
      _expectHours(_day('2026-10-16', grouped['2026-10-16']!),
          total: 10.5, regular: 1.5, extra50: 2, extra100: 7);
    });

    test('entrada 23:50 arredonda para domingo: start_date do dia seguinte',
        () {
      final day = _day('2026-10-17', [
        _punch('in', 'check_in', '2026-10-17T23:50:00.000'),
        _punch('out', 'check_out', '2026-10-18T07:00:00.000'),
      ]);
      expect(_columns(day), ['00:00', '07:00', null, null, null, null]);
      expect(day['start_date'], '2026-10-18');
      _expectHours(day, total: 7, extra100: 7);

      final normal = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T12:00:00.000'),
      ]);
      expect(normal['start_date'], '2026-10-15');
    });

    test('08-17 e 22:00-02:00 = 12h, a noite a 100%', () {
      final records = [
        _punch('in1', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out1', 'check_out', '2026-10-15T17:00:00.000'),
        _punch('in2', 'check_in', '2026-10-15T22:00:00.000'),
        _punch('out2', 'check_out', '2026-10-16T02:00:00.000'),
      ];
      final grouped = groupRecordsByWorkDay(records);
      expect(grouped.keys, ['2026-10-15']);
      final day = _day('2026-10-15', grouped['2026-10-15']!);
      expect(_columns(day),
          ['08:00', '12:00', '13:00', '17:00', '22:00', '02:00']);
      _expectHours(day, total: 12, regular: 8, extra100: 4);
    });

    test('mais de 3 sessoes junta o menor intervalo', () {
      // 08-17 (almoco automatico) e 19:30-07:00 (jantar automatico) dao 4
      // sessoes; o almoco 12-13 passa a contar para caber nas 3 colunas.
      final day = _day('2026-10-15', [
        _punch('in1', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out1', 'check_out', '2026-10-15T17:00:00.000'),
        _punch('in2', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('out2', 'check_out', '2026-10-16T07:00:00.000'),
      ]);
      expect(_columns(day),
          ['08:00', '17:00', '19:30', '20:00', '21:00', '07:00']);
      _expectHours(day, total: 19.5, regular: 12.5, extra100: 7);
    });

    test('sabado 19:30 ate domingo 07:00: domingo inteiro a 100%', () {
      final day = _day('2026-10-17', [
        _punch('in', 'check_in', '2026-10-17T19:30:00.000'),
        _punch('out', 'check_out', '2026-10-18T07:00:00.000'),
      ]);
      // Sabado 19:30-20:00 e 21:00-22:00 a 50%; 22h em diante a 100%,
      // inclusive 05-07 de domingo.
      _expectHours(day, total: 10.5, extra50: 1.5, extra100: 9);
    });

    test('feriado 20/11/2026 08-17: tudo a 100%', () {
      final day = _day('2026-11-20', [
        _punch('in', 'check_in', '2026-11-20T08:00:00.000'),
        _punch('out', 'check_out', '2026-11-20T17:00:00.000'),
      ]);
      _expectHours(day, total: 8, extra100: 8);
    });

    test('retorno batido vale mais que o fechamento automatico', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('b1', 'break_start', '2026-10-15T12:00:00.000'),
        _punch('autoclose_b1', 'break_end', '2026-10-15T13:00:00.000'),
        _punch('b2', 'break_end', '2026-10-15T13:30:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', '12:00', '13:30', '17:00', null, null]);
      _expectHours(day, total: 7.5, regular: 7.5);

      final flagged = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('j1', 'entry_3', '2026-10-15T23:00:00.000'),
        {
          ..._punch('auto', 'exit_3', '2026-10-16T00:00:00.000'),
          'auto_closed': true,
        },
        _punch('j2', 'exit_3', '2026-10-16T00:30:00.000'),
        _punch('out', 'check_out', '2026-10-16T07:00:00.000'),
      ]);
      expect(
          _columns(flagged), ['19:30', '23:00', '00:30', '07:00', null, null]);
    });

    test('so o fechamento automatico: vale ele', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('b1', 'break_start', '2026-10-15T12:00:00.000'),
        _punch('autoclose_b1', 'break_end', '2026-10-15T13:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      _expectHours(day, total: 8, regular: 8);
    });

    test('turno aberto mostra so a entrada', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:10:00.000'),
        _punch('b1', 'break_start', '2026-10-15T12:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', null, null, null, null, null]);
      _expectHours(day, total: 0);
    });

    test('saida do app antes da primeira entrada do dia e ignorada', () {
      final day = _day('2026-10-15', [
        _punch('late', 'check_out', '2026-10-15T07:50:00.000'),
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', '12:00', '13:00', '17:00', null, null]);
      _expectHours(day, total: 8, regular: 8);
    });

    test('pausa aberta fecha com 1h', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('b1', 'break_start', '2026-10-15T12:30:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', '12:30', '13:30', '17:00', null, null]);
      _expectHours(day, total: 8, regular: 8);
    });

    test('duas pausas do mesmo tipo descontam as duas', () {
      // Pausa 1 do app 12:00-13:00 e outra Pausa 1 15:00-15:30 (lote): a
      // segunda era ignorada e paga como trabalhada.
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:10.000'),
        _punch('b1', 'break_start', '2026-10-15T12:00:05.000'),
        _punch('b2', 'break_end', '2026-10-15T13:00:08.000'),
        _batch('b3', 'break_start', '2026-10-15T15:00:00.000'),
        _batch('b4', 'break_end', '2026-10-15T15:30:00.000'),
        _punch('out', 'check_out', '2026-10-15T18:00:20.000'),
      ]);
      expect(_columns(day),
          ['08:00', '12:00', '13:00', '15:00', '15:30', '18:00']);
      _expectHours(day, total: 8.5, regular: 8.5);

      // Retorno batido depois do automatico vale na primeira pausa, e a
      // segunda pausa do tipo continua contando.
      final late = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('b1', 'break_start', '2026-10-15T12:00:00.000'),
        _punch('autoclose_b1', 'break_end', '2026-10-15T13:00:00.000'),
        _punch('b2', 'break_end', '2026-10-15T13:30:00.000'),
        _batch('b3', 'break_start', '2026-10-15T15:00:00.000'),
        _batch('b4', 'break_end', '2026-10-15T15:30:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(late),
          ['08:00', '12:00', '13:30', '15:00', '15:30', '17:00']);
      _expectHours(late, total: 7, regular: 7);
    });

    test('inicio repetido com a pausa aberta vale o primeiro', () {
      final day = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('b1', 'break_start', '2026-10-15T12:00:05.000'),
        _punch('b1x', 'break_start', '2026-10-15T12:20:00.000'),
        _punch('b2', 'break_end', '2026-10-15T12:40:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(day), ['08:00', '12:00', '12:30', '17:00', null, null]);
      _expectHours(day, total: 8.5, regular: 8.5);
    });

    test('pausas no mesmo horario: de 0 min e uma emendada na outra', () {
      // Inicio e fim iguais: pausa de 0 min, nao a de 1h da pausa aberta.
      final zero = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _batch('b1', 'break_start', '2026-10-15T12:00:00.000'),
        _batch('b2', 'break_end', '2026-10-15T12:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(_columns(zero), ['08:00', '12:00', '12:00', '17:00', null, null]);
      _expectHours(zero, total: 9, regular: 9);

      // Pausa 1 12:00-12:30 e outra Pausa 1 12:30-13:00: o fim fecha a
      // primeira antes de a segunda comecar.
      final joined = _day('2026-10-15', [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _batch('b1', 'break_start', '2026-10-15T12:00:00.000'),
        _batch('b3', 'break_start', '2026-10-15T12:30:00.000'),
        _batch('b2', 'break_end', '2026-10-15T12:30:00.000'),
        _batch('b4', 'break_end', '2026-10-15T13:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
      ]);
      expect(
          _columns(joined), ['08:00', '12:00', '13:00', '17:00', null, null]);
      _expectHours(joined, total: 8, regular: 8);
    });

    test('fim da pausa e saida no mesmo horario, em qualquer ordem', () {
      // Lote de 16/10 com Pausa 1 fim 07:00 e Saida 07:00 (mesmo
      // timestamp) para a pausa deixada aberta as 03:00 no app. A ordem dos
      // dois vinha do id do Firestore: 6,5h ou 10,5h.
      final records = [
        _punch('in', 'check_in', '2026-10-15T19:30:12.000'),
        _punch('p1', 'break_start', '2026-10-16T03:00:05.000'),
        {
          ..._punch('autoclose_p1', 'break_end', '2026-10-16T04:00:05.000'),
          'auto_closed': true,
        },
        _batch('zz', 'break_end', '2026-10-16T07:00:00.000'),
        _batch('aa', 'check_out', '2026-10-16T07:00:00.000'),
      ];
      for (final order in [records, records.reversed.toList()]) {
        final days = _workDays(order);
        expect(days.keys, ['2026-10-15']);
        expect(_columns(days['2026-10-15']!),
            ['19:30', '20:00', '21:00', '03:00', null, null]);
        _expectHours(days['2026-10-15']!,
            total: 6.5, regular: 1.5, extra100: 5);
      }
    });

    test('estagiario: normal so das 13:30 as 19:30 em dia util', () {
      final day = _day(
        '2026-10-15',
        [
          _punch('in', 'check_in', '2026-10-15T12:30:00.000'),
          _punch('out', 'check_out', '2026-10-15T19:30:00.000'),
        ],
        role: 'intern',
      );
      _expectHours(day, total: 7, regular: 6);
    });
  });

  group('computeWorkDay com o lote novo (data real)', () {
    test('noite 19:30 ate 07:00 do dia seguinte = 10,5h no dia da entrada',
        () {
      final days = _workDays([
        _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _batch('out', 'check_out', '2026-10-16T07:00:00.000'),
      ]);
      expect(days.keys, ['2026-10-15']);
      expect(_columns(days['2026-10-15']!),
          ['19:30', '20:00', '21:00', '07:00', null, null]);
      _expectHours(days['2026-10-15']!,
          total: 10.5, regular: 3.5, extra100: 7);
    });

    test('noite com Pausa 1 02:00-03:00 no dia seguinte = 10,5h', () {
      final days = _workDays([
        _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _batch('b1', 'break_start', '2026-10-16T02:00:00.000'),
        _batch('b2', 'break_end', '2026-10-16T03:00:00.000'),
        _batch('out', 'check_out', '2026-10-16T07:00:00.000'),
      ]);
      expect(days.keys, ['2026-10-15']);
      expect(_columns(days['2026-10-15']!),
          ['19:30', '02:00', '03:00', '07:00', null, null]);
      _expectHours(days['2026-10-15']!,
          total: 10.5, regular: 4.5, extra100: 6);
    });

    test('turno do dia e noite do lote na mesma data contam os dois', () {
      // 08-17 do app e a noite 19:30-07:00 do lote: igual a dobra do app.
      final appDay = _workDays([
        _punch('in1', 'check_in', '2026-10-15T08:01:00.000'),
        _punch('out1', 'check_out', '2026-10-15T17:02:00.000'),
        _batch('nin', 'check_in', '2026-10-15T19:30:00.000'),
        _batch('nout', 'check_out', '2026-10-16T07:00:00.000'),
      ]);
      expect(appDay.keys, ['2026-10-15']);
      expect(_columns(appDay['2026-10-15']!),
          ['08:00', '17:00', '19:30', '20:00', '21:00', '07:00']);
      _expectHours(appDay['2026-10-15']!,
          total: 19.5, regular: 12.5, extra100: 7);

      // 06:50-16:00 e 19:00-07:00, tudo no lote (dois lancamentos): a
      // saida 07:00 da noite fica no dia 15, sem nada para adivinhar.
      final batchDay = _workDays([
        _batch('in1', 'check_in', '2026-10-14T06:50:00.000'),
        _batch('out1', 'check_out', '2026-10-14T16:00:00.000'),
        _batch('nin', 'check_in', '2026-10-14T19:00:00.000'),
        _batch('nout', 'check_out', '2026-10-15T07:00:00.000'),
      ]);
      expect(batchDay.keys, ['2026-10-14']);
      expect(_columns(batchDay['2026-10-14']!),
          ['07:00', '16:00', '19:00', '20:00', '21:00', '07:00']);
      _expectHours(batchDay['2026-10-14']!,
          total: 20, regular: 13, extra100: 7);
    });

    test('so a saida, na data real, corrige o "Esqueci" da noite anterior',
        () {
      final days = _workDays([
        _punch('in', 'check_in', '2026-10-14T19:30:12.345'),
        _punch('forgot_in', 'check_out', '2026-10-14T19:30:13.345'),
        _batch('real', 'check_out', '2026-10-15T07:00:00.000'),
        _punch('next', 'check_in', '2026-10-15T19:30:00.000'),
      ]);
      expect(_columns(days['2026-10-14']!),
          ['19:30', '20:00', '21:00', '07:00', null, null]);
      _expectHours(days['2026-10-14']!,
          total: 10.5, regular: 3.5, extra100: 7);
      expect(_columns(days['2026-10-15']!),
          ['19:30', null, null, null, null, null]);
      _expectHours(days['2026-10-15']!, total: 0);
    });

    test('saida antes da entrada na mesma data nao vira noite', () {
      // Igual a noite do lote antigo, mas com batch_real_dates: a saida
      // 07:00 e solta e a entrada 19:30 fica aberta, sem horas.
      final days = _workDays([
        _batch('out', 'check_out', '2026-10-15T07:00:00.000'),
        _batch('b1', 'break_start', '2026-10-15T02:00:00.000'),
        _batch('b2', 'break_end', '2026-10-15T03:00:00.000'),
        _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
      ]);
      expect(days.keys, ['2026-10-15']);
      expect(_columns(days['2026-10-15']!),
          ['19:30', null, null, null, null, null]);
      _expectHours(days['2026-10-15']!, total: 0);

      // O mesmo com os pontos do lote antigo: a noite de 10,5h.
      final legacy = _workDays([
        _manual('out', 'check_out', '2026-10-15T07:00:00.000'),
        _manual('b1', 'break_start', '2026-10-15T02:00:00.000'),
        _manual('b2', 'break_end', '2026-10-15T03:00:00.000'),
        _manual('in', 'check_in', '2026-10-15T19:30:00.000'),
      ]);
      _expectHours(legacy['2026-10-15']!,
          total: 10.5, regular: 4.5, extra100: 6);
    });

    test('noite do app e dia do lote no mesmo minuto: os dois valem', () {
      // A Entrada 07:00 do lote (07:00:00.000) vinha antes da Saida
      // 07:00:14 do app: a saida virava o "Esqueci" do dia e a noite
      // pagava 0h.
      final records = [
        _punch('nin', 'check_in', '2026-10-15T19:00:12.345'),
        _punch('nout', 'check_out', '2026-10-16T07:00:14.512'),
        _batch('din', 'check_in', '2026-10-16T07:00:00.000'),
        _batch('dout', 'check_out', '2026-10-16T15:00:00.000'),
      ];
      for (final order in [records, records.reversed.toList()]) {
        final days = _workDays(order);
        expect(_columns(days['2026-10-15']!),
            ['19:00', '20:00', '21:00', '07:00', null, null]);
        _expectHours(days['2026-10-15']!,
            total: 11, regular: 4, extra100: 7);
        expect(_columns(days['2026-10-16']!),
            ['07:00', '12:00', '13:00', '15:00', null, null]);
        _expectHours(days['2026-10-16']!, total: 7, regular: 7);
      }
    });

    test('dia do app e noite do lote no mesmo minuto: 23h', () {
      final records = [
        _punch('din', 'check_in', '2026-10-14T07:00:05.000'),
        _punch('dout', 'check_out', '2026-10-14T19:00:15.000'),
        _batch('nin', 'check_in', '2026-10-14T19:00:00.000'),
        _batch('nout', 'check_out', '2026-10-15T07:00:00.000'),
      ];
      for (final order in [records, records.reversed.toList()]) {
        final days = _workDays(order);
        expect(days.keys, ['2026-10-14']);
        _expectHours(days['2026-10-14']!,
            total: 23, regular: 16, extra100: 7);
      }
    });

    test('saida do lote no minuto do fim da pausa do app: pausa descontada',
        () {
      final records = [
        _punch('in', 'check_in', '2026-10-15T19:30:12.000'),
        _punch('p1', 'break_start', '2026-10-16T03:00:05.000'),
        _punch('p2', 'break_end', '2026-10-16T07:00:20.000'),
        _batch('out', 'check_out', '2026-10-16T07:00:00.000'),
      ];
      for (final order in [records, records.reversed.toList()]) {
        final days = _workDays(order);
        expect(days.keys, ['2026-10-15']);
        expect(_columns(days['2026-10-15']!),
            ['19:30', '20:00', '21:00', '03:00', null, null]);
        _expectHours(days['2026-10-15']!,
            total: 6.5, regular: 1.5, extra100: 5);
      }
    });

    test('fim da pausa do lote igual a saida do FECHAR PONTO do backend', () {
      // O backend grava a saida sem a fracao ("...19:30:00"); o lote grava
      // "...19:30:00.000". Pelo texto, o fim da pausa vinha depois da saida
      // e sumia.
      Map<String, dynamic> internDay(List<Map<String, dynamic>> records) {
        final grouped = groupRecordsByWorkDay(records);
        expect(grouped.keys, ['2026-10-15']);
        return _day('2026-10-15', grouped['2026-10-15']!, role: 'intern');
      }

      final pause2 = [
        _punch('in', 'check_in', '2026-10-15T13:30:12.345678'),
        _punch('e3', 'entry_3', '2026-10-15T18:00:05.123000'),
        _punch('out', 'check_out', '2026-10-15T19:30:00'),
        _batch('x3', 'exit_3', '2026-10-15T19:30:00.000'),
      ];
      for (final order in [pause2, pause2.reversed.toList()]) {
        final day = internDay(order);
        expect(_columns(day), ['13:30', '18:00', null, null, null, null]);
        _expectHours(day, total: 4.5, regular: 4.5);
      }

      // O fim real do lote substitui o automatico das 17:00.
      final autoClosed = [
        _punch('in', 'check_in', '2026-10-15T13:30:12.345678'),
        _punch('b1', 'break_start', '2026-10-15T16:00:05.123000'),
        {
          ..._punch('autoclose_b1', 'break_end', '2026-10-15T17:00:05.123000'),
          'auto_closed': true,
        },
        _punch('out', 'check_out', '2026-10-15T19:30:00'),
        _batch('b2', 'break_end', '2026-10-15T19:30:00.000'),
      ];
      for (final order in [autoClosed, autoClosed.reversed.toList()]) {
        final day = internDay(order);
        expect(_columns(day), ['13:30', '16:00', null, null, null, null]);
        _expectHours(day, total: 2.5, regular: 2.5);
      }
    });
  });

  group('classifyWorkMinutes', () {
    test('cada minuto pelo proprio dia', () {
      final minutes = classifyWorkMinutes(
          DateTime(2026, 10, 17, 21), DateTime(2026, 10, 18, 6), 'employee');
      expect(minutes, {
        'normal': 0,
        'extras': 0,
        'extra50': 60,
        'extra100': 8 * 60,
      });
    });
  });

  test('deslocamento de 20h ligado ao turno soma tudo no dia da entrada', () {
    // 09/11/2026: jornada sem limite. 21:00 de terca ate 17:00 de quarta, com
    // pausa 15:00-15:30; os pontos depois da entrada vem com shift_entry_id.
    Map<String, dynamic> linked(String id, String type, String ts) =>
        {..._punch(id, type, ts), 'shift_entry_id': 'in'};
    final days = _workDays([
      _punch('in', 'check_in', '2026-11-03T21:00:00'),
      linked('p1', 'break_start', '2026-11-04T15:00:00'),
      linked('p2', 'break_end', '2026-11-04T15:30:00'),
      linked('out', 'check_out', '2026-11-04T17:00:00'),
    ]);
    expect(days.keys, ['2026-11-03']);
    expect(days['2026-11-03']!['total_hours'], 19.5);
    // Sem a ligacao (ponto antigo), a saida 20h depois nao fecha o turno.
    final old = _workDays([
      _punch('in', 'check_in', '2026-11-03T21:00:00'),
      _punch('out', 'check_out', '2026-11-04T17:00:00'),
    ]);
    expect(old['2026-11-03']!['total_hours'], 0);
  });
}
