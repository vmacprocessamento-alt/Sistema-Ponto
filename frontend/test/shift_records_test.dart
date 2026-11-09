import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/shift_records.dart';

Map<String, dynamic> _punch(String id, String type, String timestamp) =>
    {'id': id, 'record_type': type, 'timestamp': timestamp};

// Ponto lancado pelo gestor no lote ANTIGO (createTimeRecord para outro
// usuario, todos os horarios na data escolhida).
Map<String, dynamic> _manual(String id, String type, String timestamp) =>
    {..._punch(id, type, timestamp), 'created_by_admin': true};

// Ponto do lote novo: data real e batch_real_dates.
Map<String, dynamic> _batch(String id, String type, String timestamp) =>
    {..._manual(id, type, timestamp), 'batch_real_dates': true};

List<String> _ids(List<Map<String, dynamic>>? records) =>
    (records ?? []).map((record) => record['id'] as String).toList();

void main() {
  group('isLegacyBatchRecord', () {
    test('so o ponto do gestor sem batch_real_dates e do lote antigo', () {
      expect(isLegacyBatchRecord(_manual('a', 'check_in', '2026-10-15T19:30')),
          isTrue);
      expect(isLegacyBatchRecord(_batch('b', 'check_in', '2026-10-15T19:30')),
          isFalse);
      expect(isLegacyBatchRecord(_punch('c', 'check_in', '2026-10-15T19:30')),
          isFalse);
      expect(
          isLegacyBatchRecord({
            ..._manual('d', 'check_in', '2026-10-15T19:30'),
            'batch_real_dates': false,
          }),
          isTrue);
    });
  });

  group('openShiftCheckIn', () {
    test('entrada de ontem sem saida continua aberta', () {
      final open = openShiftCheckIn([
        _punch('a', 'check_in', '2026-10-14T08:00:00'),
        _punch('b', 'check_out', '2026-10-14T17:00:00'),
        _punch('c', 'check_in', '2026-10-15T19:30:00'),
      ]);
      expect(open?['id'], 'c');
    });

    test('saida depois da entrada fecha o turno', () {
      final open = openShiftCheckIn([
        _punch('b', 'check_out', '2026-10-16T07:00:00'),
        _punch('a', 'check_in', '2026-10-15T19:30:00'),
      ]);
      expect(open, isNull);
    });

    test('turno da noite do lote do gestor ja vem fechado', () {
      final open = openShiftCheckIn([
        _manual('out', 'check_out', '2026-10-15T07:00:00'),
        _manual('in', 'check_in', '2026-10-15T19:30:00'),
      ]);
      expect(open, isNull);
    });

    test('noite do lote na data de um turno do app ja vem fechada', () {
      final open = openShiftCheckIn([
        _punch('in1', 'check_in', '2026-10-15T08:01:00'),
        _punch('out1', 'check_out', '2026-10-15T17:02:00'),
        _manual('nout', 'check_out', '2026-10-15T07:00:00'),
        _manual('nin', 'check_in', '2026-10-15T19:30:00'),
      ]);
      expect(open, isNull);
    });

    test('entrada do gestor sem saida no lote continua aberta', () {
      final open = openShiftCheckIn([
        _punch('out', 'check_out', '2026-10-15T07:00:00'),
        _manual('in', 'check_in', '2026-10-15T19:30:00'),
      ]);
      expect(open?['id'], 'in');
    });

    test('lote novo: a saida do dia seguinte fecha a noite, como no app', () {
      expect(
          openShiftCheckIn([
            _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
            _batch('out', 'check_out', '2026-10-16T07:00:00.000'),
          ]),
          isNull);
      // So a entrada lancada: o turno fica aberto.
      expect(
          openShiftCheckIn([
            _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
          ])?['id'],
          'in');
    });

    test('lote novo com saida antes da entrada na mesma data nao e noite', () {
      // Parece a noite do lote antigo, mas os dois tem a data real: a saida
      // 07:00 e solta e a entrada 19:30 continua aberta.
      final ordered = [
        _batch('out', 'check_out', '2026-10-15T07:00:00.000'),
        _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
      ];
      expect(manualNightExitIndex(ordered, 1), isNull);
      expect(manualNightMorning(ordered, 1), isEmpty);
      expect(openShiftCheckIn(ordered)?['id'], 'in');

      // Mistura: entrada do lote antigo com saida do lote novo, ou o
      // contrario, tambem nao e noite.
      final legacyEntry = [
        _batch('out', 'check_out', '2026-10-15T07:00:00.000'),
        _manual('in', 'check_in', '2026-10-15T19:30:00.000'),
      ];
      expect(manualNightExitIndex(legacyEntry, 1), isNull);
      expect(openShiftCheckIn(legacyEntry)?['id'], 'in');
      final legacyExit = [
        _manual('out', 'check_out', '2026-10-15T07:00:00.000'),
        _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
      ];
      expect(manualNightExitIndex(legacyExit, 1), isNull);
      expect(openShiftCheckIn(legacyExit)?['id'], 'in');
    });
  });

  group('dayStartWithoutShift', () {
    final night = [
      _batch('bs', 'break_start', '2026-10-16T02:00:00.000'),
      _batch('be', 'break_end', '2026-10-16T03:00:00.000'),
      _batch('out', 'check_out', '2026-10-16T07:00:00.000'),
      _punch('in16', 'check_in', '2026-10-16T08:00:00.000'),
    ];

    test('madrugada sem a entrada na vespera lida', () {
      // Vespera lida antes do lote da noite: so o 08-17.
      final stale = [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out15', 'check_out', '2026-10-15T17:00:00.000'),
      ];
      expect(dayStartWithoutShift(stale, night)?['id'], 'bs');
      expect(
          dayStartWithoutShift(
              [...stale, _batch('nin', 'check_in', '2026-10-15T19:30:00.000')],
              night),
          isNull);
    });

    test('dia que comeca na entrada ou sem pontos', () {
      expect(dayStartWithoutShift(const [], night.sublist(3)), isNull);
      expect(dayStartWithoutShift(const [], const []), isNull);
    });

    test('entrada aberta a mais de 16h nao explica o dia', () {
      expect(
          dayStartWithoutShift(
              [_punch('in', 'check_in', '2026-10-15T08:00:00.000')], night),
          isNotNull);
    });
  });

  group('manualNightExitIndex', () {
    test('aponta a saida do gestor gravada antes da entrada', () {
      final ordered = [
        _manual('out', 'check_out', '2026-10-15T07:00:00'),
        _manual('pause', 'break_start', '2026-10-15T08:00:00'),
        _manual('in', 'check_in', '2026-10-15T19:30:00'),
      ];
      expect(manualNightExitIndex(ordered, 2), 0);
      expect(manualNightExitIndex(ordered, 0), isNull);
    });

    test('entrada do app ou com saida depois nao e noite do lote', () {
      final fromApp = [
        _manual('out', 'check_out', '2026-10-15T07:00:00'),
        _punch('in', 'check_in', '2026-10-15T19:30:00'),
      ];
      expect(manualNightExitIndex(fromApp, 1), isNull);
      final dayShift = [
        _manual('in', 'check_in', '2026-10-15T08:00:00'),
        _manual('out', 'check_out', '2026-10-15T17:00:00'),
      ];
      expect(manualNightExitIndex(dayShift, 0), isNull);
    });

    test('dobra no lote: a saida da noite e a de antes da primeira entrada',
        () {
      final ordered = [
        _manual('nout', 'check_out', '2026-10-15T07:00:00'),
        _manual('in1', 'check_in', '2026-10-15T08:00:00'),
        _manual('out1', 'check_out', '2026-10-15T17:00:00'),
        _manual('nin', 'check_in', '2026-10-15T19:30:00'),
      ];
      expect(manualNightExitIndex(ordered, 3), 0);
      expect(manualNightExitIndex(ordered, 1), isNull);
    });

    test('dobra com o dia comecando antes da saida da noite', () {
      // 06:50-16:00 do app e a noite 19:00-07:00 do lote na mesma data: a
      // saida 07:00 cai depois da entrada 06:50, e a 16:00 a substitui.
      final ordered = [
        _punch('in1', 'check_in', '2026-10-14T06:50:00'),
        _manual('nout', 'check_out', '2026-10-14T07:00:00'),
        _punch('out1', 'check_out', '2026-10-14T16:00:00'),
        _manual('nin', 'check_in', '2026-10-14T19:00:00'),
      ];
      expect(manualNightExitIndex(ordered, 3), 1);
      expect(manualNightMorning(ordered, 3), [1]);
      expect(openShiftCheckIn(ordered), isNull);

      // Saida do gestor que nenhuma outra substitui fecha o turno do dia.
      final dayExit = [
        _punch('in1', 'check_in', '2026-10-14T06:50:00'),
        _manual('out1', 'check_out', '2026-10-14T16:00:00'),
        _manual('nin', 'check_in', '2026-10-14T19:00:00'),
      ];
      expect(manualNightExitIndex(dayExit, 2), isNull);
      expect(openShiftCheckIn(dayExit)?['id'], 'nin');
    });

    test('pausas da madrugada da noite antes da entrada do turno do dia', () {
      final ordered = [
        _manual('p1', 'break_start', '2026-10-14T02:00:00'),
        _manual('p2', 'break_end', '2026-10-14T03:00:00'),
        _manual('in1', 'check_in', '2026-10-14T06:00:00'),
        _manual('nout', 'check_out', '2026-10-14T07:00:00'),
        _manual('out1', 'check_out', '2026-10-14T15:00:00'),
        _manual('nin', 'check_in', '2026-10-14T19:00:00'),
      ];
      expect(manualNightMorning(ordered, 5), [0, 1, 3]);
    });

    test('noite do lote vai no maximo 16h', () {
      // Entrada 08:00 do gestor no dia da saida 07:00 que corrige o
      // "Esqueci" da vespera: e o turno do dia, aberto, nao noite de 23h.
      final ordered = [
        _punch('in15', 'check_in', '2026-10-15T19:30:00'),
        _punch('forgot_in15', 'check_out', '2026-10-15T19:30:01'),
        _manual('fix', 'check_out', '2026-10-16T07:00:00'),
        _manual('in16', 'check_in', '2026-10-16T08:00:00'),
      ];
      expect(manualNightExitIndex(ordered, 3), isNull);
      expect(openShiftCheckIn(ordered)?['id'], 'in16');
      final grouped = groupRecordsByWorkDay(ordered);
      expect(_ids(grouped['2026-10-15']), ['in15', 'forgot_in15', 'fix']);
      expect(_ids(grouped['2026-10-16']), ['in16']);
    });
  });

  group('manualNightMorning', () {
    test('saida e pausas da madrugada da noite, sem as do turno do dia', () {
      final ordered = [
        _manual('p1', 'break_start', '2026-10-15T02:00:00'),
        _manual('p2', 'break_end', '2026-10-15T03:00:00'),
        _manual('nout', 'check_out', '2026-10-15T07:00:00'),
        _manual('in1', 'check_in', '2026-10-15T08:00:00'),
        _manual('l1', 'break_start', '2026-10-15T12:00:00'),
        _manual('l2', 'break_end', '2026-10-15T13:00:00'),
        _manual('out1', 'check_out', '2026-10-15T17:00:00'),
        _manual('nin', 'check_in', '2026-10-15T19:30:00'),
      ];
      expect(manualNightMorning(ordered, 7), [0, 1, 2]);
      expect(manualNightMorning(ordered, 3), isEmpty);
      expect(allManualNightMorning(ordered), {0, 1, 2});
    });

    test('pausas do lote antigo antes da saida do app da noite anterior', () {
      // Noite do app em 14/10 (saida 15/10 07:00:20) e noite do lote antigo
      // em 15/10, toda gravada em 15/10, com a saida 07:25 depois da do app:
      // a Pausa 2 03:00-03:30 e da noite do lote, nao da noite do app.
      final ordered = [
        _punch('in14', 'check_in', '2026-10-14T19:30:00.000'),
        _manual('j1', 'entry_3', '2026-10-15T03:00:00.000'),
        _manual('j2', 'exit_3', '2026-10-15T03:30:00.000'),
        _punch('out14', 'check_out', '2026-10-15T07:00:20.000'),
        _manual('nout', 'check_out', '2026-10-15T07:25:00.000'),
        _manual('nin', 'check_in', '2026-10-15T16:50:00.000'),
        _manual('p1', 'break_start', '2026-10-15T22:00:00.000'),
        _manual('p2', 'break_end', '2026-10-15T23:00:00.000'),
      ];
      expect(manualNightMorning(ordered, 5), [1, 2, 4]);
      final grouped = groupRecordsByWorkDay(ordered);
      expect(_ids(grouped['2026-10-14']), ['in14', 'out14']);
      expect(_ids(grouped['2026-10-15']),
          ['j1', 'j2', 'nout', 'nin', 'p1', 'p2']);

      // Outra saida do lote antigo no meio ainda encerra a busca: as pausas
      // antes dela nao sao da noite.
      final legacyBetween = [
        ...ordered.take(3),
        _manual('fix', 'check_out', '2026-10-15T06:00:00.000'),
        ...ordered.skip(4),
      ];
      expect(manualNightMorning(legacyBetween, 5), [4]);
    });
  });

  group('groupRecordsByWorkDay', () {
    test('turno que passa da meia-noite fica no dia da entrada', () {
      final grouped = groupRecordsByWorkDay([
        _punch('out', 'check_out', '2026-10-16T07:00:00'),
        _punch('pause', 'break_start', '2026-10-16T01:00:00'),
        _punch('in', 'check_in', '2026-10-15T19:30:00'),
      ]);
      expect(grouped.keys, ['2026-10-15']);
      expect(_ids(grouped['2026-10-15']), ['in', 'pause', 'out']);
    });

    test('novo turno no dia seguinte volta para o proprio dia', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in1', 'check_in', '2026-10-15T19:30:00'),
        _punch('out1', 'check_out', '2026-10-16T07:00:00'),
        _punch('in2', 'check_in', '2026-10-16T19:30:00'),
        _punch('out2', 'check_out', '2026-10-17T07:00:00'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in1', 'out1']);
      expect(_ids(grouped['2026-10-16']), ['in2', 'out2']);
    });

    test('saida esquecida batida na manha seguinte fica no proprio dia', () {
      // Entrada 08:00 sem saida; 07:50 do dia seguinte nao e turno de 24h.
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-14T08:00:00'),
        _punch('out', 'check_out', '2026-10-15T07:50:00'),
        _punch('next', 'check_in', '2026-10-15T08:00:00'),
      ]);
      expect(_ids(grouped['2026-10-14']), ['in']);
      expect(_ids(grouped['2026-10-15']), ['out', 'next']);
    });

    test('jornada sem limite: ponto ligado ao turno passa de 16h e fica nele',
        () {
      // Deslocamento 21:00 ate 17:00 do dia seguinte (20h): a pausa 15:00 e a
      // saida vem com shift_entry_id (o servidor grava, 09/11/2026).
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-11-03T21:00:00'),
        {
          ..._punch('p1', 'break_start', '2026-11-04T15:00:00'),
          'shift_entry_id': 'in',
        },
        {
          ..._punch('p2', 'break_end', '2026-11-04T15:30:00'),
          'shift_entry_id': 'in',
        },
        {
          ..._punch('out', 'check_out', '2026-11-04T17:00:00'),
          'shift_entry_id': 'in',
        },
      ]);
      expect(_ids(grouped['2026-11-03']), ['in', 'p1', 'p2', 'out']);
      expect(grouped['2026-11-04'], isNull);
    });

    test('saida do Esqueci corrigida pelo gestor para mais de 16h fica no turno',
        () {
      final grouped = groupRecordsByWorkDay([
        _punch('in1', 'check_in', '2026-11-03T21:24:42'),
        _punch('forgot_in1', 'check_out', '2026-11-04T15:00:00'),
      ]);
      expect(_ids(grouped['2026-11-03']), ['in1', 'forgot_in1']);
    });

    test('ponto ligado a outra entrada nao entra no turno aberto', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-14T08:00:00'),
        {
          ..._punch('out', 'check_out', '2026-10-15T07:50:00'),
          'shift_entry_id': 'outra',
        },
      ]);
      expect(_ids(grouped['2026-10-14']), ['in']);
      expect(_ids(grouped['2026-10-15']), ['out']);
    });

    test('noites seguidas no lote do gestor ficam cada uma no seu dia', () {
      // Lote grava saida 07:00 e entrada 19:30 na mesma data escolhida.
      final grouped = groupRecordsByWorkDay([
        _manual('out15', 'check_out', '2026-10-15T07:00:00'),
        _manual('in15', 'check_in', '2026-10-15T19:30:00'),
        _manual('out16', 'check_out', '2026-10-16T07:00:00'),
        _manual('in16', 'check_in', '2026-10-16T19:30:00'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['out15', 'in15']);
      expect(_ids(grouped['2026-10-16']), ['out16', 'in16']);
    });

    test('lote do gestor fecha a noite e lanca o dia seguinte', () {
      // Saida 07:00 da noite real e o expediente 08-17, ambos pelo gestor.
      final grouped = groupRecordsByWorkDay([
        _punch('in14', 'check_in', '2026-10-14T19:30:00'),
        _manual('out14', 'check_out', '2026-10-15T07:00:00'),
        _manual('in15', 'check_in', '2026-10-15T08:00:00'),
        _manual('out15', 'check_out', '2026-10-15T17:00:00'),
      ]);
      expect(_ids(grouped['2026-10-14']), ['in14', 'out14']);
      expect(_ids(grouped['2026-10-15']), ['in15', 'out15']);
    });

    test('saida lancada pelo gestor no dia seguinte fecha o turno aberto', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-15T19:30:00'),
        _manual('out', 'check_out', '2026-10-16T07:00:00'),
        _punch('next', 'check_in', '2026-10-16T08:00:00'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in', 'out']);
      expect(_ids(grouped['2026-10-16']), ['next']);
    });

    test('saida do lote da noite nao encerra o turno do app da vespera', () {
      // Noite do app em 14/10 e noite de 15/10 lancada no lote; a saida real
      // do app (07:00:20) vem depois da saida do lote (07:00:00).
      final grouped = groupRecordsByWorkDay([
        _punch('in14', 'check_in', '2026-10-14T19:30:00'),
        _manual('out15', 'check_out', '2026-10-15T07:00:00.000'),
        _punch('out14', 'check_out', '2026-10-15T07:00:20'),
        _manual('in15', 'check_in', '2026-10-15T19:30:00.000'),
      ]);
      expect(_ids(grouped['2026-10-14']), ['in14', 'out14']);
      expect(_ids(grouped['2026-10-15']), ['out15', 'in15']);
    });

    test('saida real lancada na manha seguinte ao "Esqueci" fica na entrada',
        () {
      final records = [
        _punch('in', 'check_in', '2026-10-14T19:30:12.345'),
        _punch('forgot_in', 'check_out', '2026-10-14T19:30:13.345'),
        _manual('real', 'check_out', '2026-10-15T07:00:00.000'),
        _punch('next', 'check_in', '2026-10-15T19:30:00'),
      ];
      final grouped = groupRecordsByWorkDay(records);
      expect(_ids(grouped['2026-10-14']), ['in', 'forgot_in', 'real']);
      expect(_ids(grouped['2026-10-15']), ['next']);
      // Para a tela, o "Esqueci" fechou o turno.
      expect(openShiftCheckIn(records.take(2))?['id'], isNull);
    });

    test('saida do gestor que corrige o "Esqueci" na data de uma noite do lote',
        () {
      final grouped = groupRecordsByWorkDay([
        _punch('in15', 'check_in', '2026-10-15T19:30:00'),
        _punch('forgot_in15', 'check_out', '2026-10-15T19:30:06'),
        _manual('fix', 'check_out', '2026-10-16T06:00:00'),
        _manual('nout', 'check_out', '2026-10-16T07:00:00'),
        _manual('nin', 'check_in', '2026-10-16T19:30:00'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in15', 'forgot_in15', 'fix']);
      expect(_ids(grouped['2026-10-16']), ['nout', 'nin']);
    });

    test('dobra no lote: o turno do dia e a noite ficam no proprio dia', () {
      // Com a regra antiga, os pontos do gestor antes da entrada da noite
      // nao fechavam nem eram agrupados com o turno aberto da vespera.
      final grouped = groupRecordsByWorkDay([
        _punch('in14', 'check_in', '2026-10-14T19:30:00'),
        _manual('out14', 'check_out', '2026-10-15T06:30:00'),
        _manual('nout', 'check_out', '2026-10-15T07:00:00'),
        _manual('in1', 'check_in', '2026-10-15T08:00:00'),
        _manual('out1', 'check_out', '2026-10-15T17:00:00'),
        _manual('nin', 'check_in', '2026-10-15T19:30:00'),
      ]);
      expect(_ids(grouped['2026-10-14']), ['in14', 'out14']);
      expect(_ids(grouped['2026-10-15']), ['nout', 'in1', 'out1', 'nin']);
    });

    test('refeicao da noite batida como saida e entrada e um dia so', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in1', 'check_in', '2026-10-15T19:30:00'),
        _punch('out1', 'check_out', '2026-10-15T23:30:00'),
        _punch('in2', 'check_in', '2026-10-16T00:30:00'),
        _punch('pause', 'break_start', '2026-10-16T03:00:00'),
        _punch('back', 'break_end', '2026-10-16T03:15:00'),
        _punch('out2', 'check_out', '2026-10-16T07:00:00'),
        _punch('next', 'check_in', '2026-10-16T19:30:00'),
      ]);
      expect(_ids(grouped['2026-10-15']),
          ['in1', 'out1', 'in2', 'pause', 'back', 'out2']);
      expect(_ids(grouped['2026-10-16']), ['next']);
    });

    test('entrada da manha depois da noite e outro dia de trabalho', () {
      // 08:00 e 1h depois da saida 07:00, mas ja e dia: dobra, nao refeicao.
      final grouped = groupRecordsByWorkDay([
        _punch('in1', 'check_in', '2026-10-15T19:30:00'),
        _punch('out1', 'check_out', '2026-10-16T07:00:00'),
        _punch('in2', 'check_in', '2026-10-16T08:00:00'),
        _punch('out2', 'check_out', '2026-10-16T17:00:00'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in1', 'out1']);
      expect(_ids(grouped['2026-10-16']), ['in2', 'out2']);
    });

    test('noite do lote novo fica no dia da entrada, pausas inclusive', () {
      final grouped = groupRecordsByWorkDay([
        _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _batch('b1', 'break_start', '2026-10-16T02:00:00.000'),
        _batch('b2', 'break_end', '2026-10-16T03:00:00.000'),
        _batch('out', 'check_out', '2026-10-16T07:00:00.000'),
      ]);
      expect(grouped.keys, ['2026-10-15']);
      expect(_ids(grouped['2026-10-15']), ['in', 'b1', 'b2', 'out']);
    });

    test('turno do dia e noite do lote novo na mesma data, sem adivinhar', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in1', 'check_in', '2026-10-14T06:50:00.000'),
        _punch('out1', 'check_out', '2026-10-14T16:00:00.000'),
        _batch('nin', 'check_in', '2026-10-14T19:00:00.000'),
        _batch('nout', 'check_out', '2026-10-15T07:00:00.000'),
        _punch('in2', 'check_in', '2026-10-15T08:00:00.000'),
      ]);
      expect(_ids(grouped['2026-10-14']), ['in1', 'out1', 'nin', 'nout']);
      expect(_ids(grouped['2026-10-15']), ['in2']);
    });

    test('saida do lote novo no dia seguinte corrige o "Esqueci" da noite', () {
      // Lote so com a saida, na data real 16/10: fecha a noite de 15/10.
      final records = [
        _punch('in15', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('forgot_in15', 'check_out', '2026-10-15T19:30:01.000'),
        _batch('fix', 'check_out', '2026-10-16T07:00:00.000'),
        _punch('in16', 'check_in', '2026-10-16T19:30:00.000'),
      ];
      final grouped = groupRecordsByWorkDay(records);
      expect(_ids(grouped['2026-10-15']), ['in15', 'forgot_in15', 'fix']);
      expect(_ids(grouped['2026-10-16']), ['in16']);
      expect(openShiftCheckIn(records)?['id'], 'in16');
    });

    test('lote novo com saida antes da entrada: saida solta, entrada aberta',
        () {
      final records = [
        _batch('out', 'check_out', '2026-10-15T07:00:00.000'),
        _batch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('late', 'break_start', '2026-10-16T13:00:00.000'),
      ];
      // A saida 07:00 nao e reservada para a entrada 19:30 (sem turno aberto,
      // fica solta no proprio dia) e a entrada 19:30 segue aberta; a pausa
      // mais de 16h depois dela fica no proprio dia.
      final grouped = groupRecordsByWorkDay(records);
      expect(_ids(grouped['2026-10-15']), ['out', 'in']);
      expect(_ids(grouped['2026-10-16']), ['late']);
      expect(allManualNightMorning(records), isEmpty);
      expect(openShiftCheckIn(records)?['id'], 'in');
    });

    test('transicao: noite do lote novo e do lote antigo em dias seguidos', () {
      // 15/10 pelo lote novo (saida 07:00 em 16/10) e 16/10 pelo lote antigo
      // (saida da manha e entrada 19:30, ambas em 16/10): cada saida no seu
      // turno, com a saida do lote antigo antes ou depois da do lote novo.
      for (final (legacyExit, nightExit) in [('06:30', 1), ('07:30', 2)]) {
        final ordered = [
          _batch('in15', 'check_in', '2026-10-15T19:30:00.000'),
          _batch('out15', 'check_out', '2026-10-16T07:00:00.000'),
          _manual('out16', 'check_out', '2026-10-16T$legacyExit:00.000'),
          _manual('in16', 'check_in', '2026-10-16T19:30:00.000'),
        ]..sort((a, b) =>
            a['timestamp'].toString().compareTo(b['timestamp'].toString()));
        expect(manualNightExitIndex(ordered, 3), nightExit);
        expect(openShiftCheckIn(ordered), isNull);
        final grouped = groupRecordsByWorkDay(ordered);
        expect(_ids(grouped['2026-10-15']), ['in15', 'out15']);
        expect(_ids(grouped['2026-10-16']), ['out16', 'in16']);
      }
    });

    test('saida repetida no dia seguinte corrige a noite que ja fechou', () {
      // Saida batida por engano as 03:00; o gestor lanca a saida 07:00 em
      // 16/10 (lote novo). Vale a ultima, como no mesmo dia.
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('wrong', 'check_out', '2026-10-16T03:00:00.000'),
        _batch('fix', 'check_out', '2026-10-16T07:00:00.000'),
        _punch('next', 'check_in', '2026-10-16T19:30:00.000'),
        _punch('late', 'check_out', '2026-10-17T07:00:00.000'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in', 'wrong', 'fix']);
      expect(_ids(grouped['2026-10-16']), ['next', 'late']);
    });

    test('pausa antes da saida que corrige a noite vai junto com ela', () {
      // Saida batida por engano as 03:00; o lote de 16/10 lanca a pausa
      // 03:30-04:30 e a saida 07:00. A pausa fica no dia da entrada, com a
      // saida, e nao solta em 16/10.
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-15T21:30:00.000'),
        _punch('wrong', 'check_out', '2026-10-16T03:00:27.000'),
        _batch('b1', 'break_start', '2026-10-16T03:30:00.000'),
        _batch('b2', 'break_end', '2026-10-16T04:30:00.000'),
        _batch('fix', 'check_out', '2026-10-16T07:00:00.000'),
        _punch('next', 'check_in', '2026-10-16T19:30:00.000'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in', 'wrong', 'b1', 'b2', 'fix']);
      expect(_ids(grouped['2026-10-16']), ['next']);
    });

    test('pausa depois do turno fechado sem saida que corrige fica no dia', () {
      final closed = [
        _punch('in', 'check_in', '2026-10-15T19:30:00.000'),
        _punch('out', 'check_out', '2026-10-16T07:00:00.000'),
      ];
      // Sem nada depois, com uma entrada depois ou com uma saida a mais de
      // 16h da entrada: a pausa e solta, do proprio dia.
      for (final after in [
        <Map<String, dynamic>>[],
        [_punch('in16', 'check_in', '2026-10-16T08:30:00.000')],
        [_punch('stray', 'check_out', '2026-10-16T12:00:00.000')],
      ]) {
        final grouped = groupRecordsByWorkDay([
          ...closed,
          _punch('pause', 'break_start', '2026-10-16T08:00:00.000'),
          ...after,
        ]);
        expect(_ids(grouped['2026-10-15']), ['in', 'out']);
        expect(_ids(grouped['2026-10-16']), ['pause', ..._ids(after)]);
      }
    });

    test('saida repetida a mais de 16h da entrada fica no proprio dia', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00.000'),
        _batch('stray', 'check_out', '2026-10-16T07:00:00.000'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in', 'out']);
      expect(_ids(grouped['2026-10-16']), ['stray']);
    });

    test('dia comum continua agrupado pela propria data', () {
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-15T08:00:00'),
        _punch('b1', 'break_start', '2026-10-15T12:00:00'),
        _punch('b2', 'break_end', '2026-10-15T13:00:00'),
        _punch('out', 'check_out', '2026-10-15T17:00:00'),
        _punch('next', 'check_in', '2026-10-16T08:00:00'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in', 'b1', 'b2', 'out']);
      expect(_ids(grouped['2026-10-16']), ['next']);
    });

    test('pausa do lote antes da saida reservada da noite do lote antigo', () {
      // 15/10 do app fechada por engano 03:00; 16/10 tem a noite do lote
      // antigo (saida 07:00 reservada e entrada 19:30). O lote novo de 16/10
      // lanca a pausa 03:30-04:30 e a saida 07:30: a pausa vai com a saida
      // que corrige a noite, nao fica solta por causa da saida reservada.
      final grouped = groupRecordsByWorkDay([
        _punch('in', 'check_in', '2026-10-15T21:30:12.000'),
        _punch('wrong', 'check_out', '2026-10-16T03:00:27.000'),
        _batch('b1', 'break_start', '2026-10-16T03:30:00.000'),
        _batch('b2', 'break_end', '2026-10-16T04:30:00.000'),
        _manual('lout', 'check_out', '2026-10-16T07:00:00.000'),
        _batch('fix', 'check_out', '2026-10-16T07:30:00.000'),
        _manual('lin', 'check_in', '2026-10-16T19:30:00.000'),
      ]);
      expect(_ids(grouped['2026-10-15']), ['in', 'wrong', 'b1', 'b2', 'fix']);
      expect(_ids(grouped['2026-10-16']), ['lout', 'lin']);
    });

    test('saida e entrada no mesmo horario: um turno fecha, outro abre', () {
      // Noite 19:00-07:00 e dia 07:00-15:00 lancados no lote: a saida da
      // noite e a entrada do dia tem o mesmo timestamp. Com a entrada
      // primeiro, a saida fechava o dia no "Esqueci" e a noite ficava
      // aberta, sem horas.
      final records = [
        _batch('nin', 'check_in', '2026-10-15T19:00:00.000'),
        _batch('a', 'check_out', '2026-10-16T07:00:00.000'),
        _batch('b', 'check_in', '2026-10-16T07:00:00.000'),
        _batch('dout', 'check_out', '2026-10-16T15:00:00.000'),
      ];
      for (final order in [
        records,
        records.reversed.toList(),
        [records[0], records[2], records[1], records[3]],
      ]) {
        final grouped = groupRecordsByWorkDay(order);
        expect(_ids(grouped['2026-10-15']), ['nin', 'a']);
        expect(_ids(grouped['2026-10-16']), ['b', 'dout']);
        expect(openShiftCheckIn(order), isNull);
        expect(openShiftCheckIn(order.where((r) => r['id'] != 'dout'))?['id'],
            'b');
      }
    });
  });

  group('compareRecords', () {
    test('mesmo timestamp: fim da pausa, saida, entrada, inicio da pausa', () {
      const at = '2026-10-16T07:00:00.000';
      final records = [
        _punch('a', 'entry_3', at),
        _punch('b', 'break_start', at),
        _punch('c', 'check_in', at),
        _punch('d', 'check_out', at),
        _punch('e', 'exit_3', at),
        _punch('f', 'break_end', at),
        _punch('g', 'check_out', '2026-10-16T06:59:59.999'),
      ];
      final expected = ['g', 'e', 'f', 'd', 'c', 'a', 'b'];
      for (final order in [records, records.reversed.toList()]) {
        expect(_ids([...order]..sort(compareRecords)), expected);
      }
      // Mais de 32 pontos (o sort do Dart deixa de ser estavel): a ordem
      // continua a mesma.
      final many = [
        for (var i = 0; i < 12; i++) ...records.map((record) => {
              ...record,
              'id': '${record['id']}$i',
            }),
      ];
      final sorted = _ids([...many]..sort(compareRecords));
      expect(_ids([...many.reversed]..sort(compareRecords)), sorted);
      expect(sorted.take(12), everyElement(startsWith('g')));
    });

    test('mesmo instante com e sem a fracao: o tipo decide', () {
      // Saida do FECHAR PONTO gravada pelo backend (isoformat, sem a
      // fracao) e o fim da pausa do lote no mesmo horario.
      final exit = _punch('out', 'check_out', '2026-10-15T19:30:00');
      final pauseEnd = _batch('p2', 'exit_3', '2026-10-15T19:30:00.000');
      expect(compareRecords(pauseEnd, exit), lessThan(0));
      expect(compareRecords(exit, pauseEnd), greaterThan(0));
      expect(_ids(sortRecords([exit, pauseEnd])), ['p2', 'out']);
      expect(_ids(sortRecords([pauseEnd, exit])), ['p2', 'out']);
      // Sem segundos tambem e o mesmo instante.
      expect(
          compareRecords(_punch('a', 'check_in', '2026-10-15T19:30'),
              _punch('b', 'check_out', '2026-10-15T19:30:00.000000')),
          greaterThan(0));
    });
  });

  group('sortRecords: lote no minuto de uma batida com segundos', () {
    List<String> sortedIds(List<Map<String, dynamic>> records) =>
        _ids(sortRecords([...records]));

    void expectInAnyOrder(
        List<Map<String, dynamic>> records, List<String> expected) {
      expect(sortedIds(records), expected);
      expect(sortedIds(records.reversed.toList()), expected);
    }

    test('entrada do lote depois da saida do app no mesmo minuto', () {
      // Noite do app e o dia lancado no lote: a Entrada 07:00 do lote ficava
      // antes da Saida 07:00:14 e a saida virava o "Esqueci" do dia.
      final records = [
        _punch('nin', 'check_in', '2026-10-15T19:00:12.345'),
        _punch('nout', 'check_out', '2026-10-16T07:00:14.512'),
        _batch('din', 'check_in', '2026-10-16T07:00:00.000'),
        _batch('dout', 'check_out', '2026-10-16T15:00:00.000'),
      ];
      expectInAnyOrder(records, ['nin', 'nout', 'din', 'dout']);
      final grouped = groupRecordsByWorkDay(records);
      expect(_ids(grouped['2026-10-15']), ['nin', 'nout']);
      expect(_ids(grouped['2026-10-16']), ['din', 'dout']);
      // So com a entrada do lote: o turno do dia fica aberto.
      final open = records.where((r) => r['id'] != 'dout').toList();
      expect(openShiftCheckIn(open)?['id'], 'din');
      expect(openShiftCheckIn(open.reversed)?['id'], 'din');
    });

    test('saida do lote antes da entrada do app no mesmo minuto', () {
      final records = [
        _batch('nin', 'check_in', '2026-10-15T19:00:00.000'),
        _batch('nout', 'check_out', '2026-10-16T07:00:00.000'),
        _punch('din', 'check_in', '2026-10-16T07:00:20.100'),
      ];
      expectInAnyOrder(records, ['nin', 'nout', 'din']);
      expect(openShiftCheckIn(records)?['id'], 'din');
    });

    test('saida do lote depois do fim da pausa do app no mesmo minuto', () {
      final records = [
        _punch('in', 'check_in', '2026-10-15T19:30:12.000'),
        _punch('b1', 'break_start', '2026-10-16T03:00:05.000'),
        _punch('b2', 'break_end', '2026-10-16T07:00:20.000'),
        _batch('out', 'check_out', '2026-10-16T07:00:00.000'),
        _batch('p2', 'exit_3', '2026-10-16T07:00:00.000'),
      ];
      // O fim da Pausa 2 do lote nao tem batida de tipo anterior no minuto:
      // fica no comeco dele.
      expectInAnyOrder(records, ['in', 'b1', 'p2', 'b2', 'out']);
    });

    test('inicio da pausa do lote depois da entrada do app', () {
      final records = [
        _punch('in', 'check_in', '2026-10-15T19:30:12.000'),
        _batch('b1', 'break_start', '2026-10-15T19:30:00.000'),
        _batch('b2', 'break_end', '2026-10-15T20:30:00.000'),
      ];
      expectInAnyOrder(records, ['in', 'b1', 'b2']);
    });

    test('batida de outro usuario no mesmo minuto nao muda a ordem', () {
      final records = [
        {..._punch('other', 'check_out', '2026-10-16T07:00:14.000'),
          'user_id': 'u2'},
        {..._batch('din', 'check_in', '2026-10-16T07:00:00.000'),
          'user_id': 'u1'},
        {..._punch('mine', 'check_in', '2026-10-16T07:00:30.000'),
          'user_id': 'u1'},
      ];
      expectInAnyOrder(records, ['din', 'other', 'mine']);
    });

    test('a saida do "Esqueci" continua depois da propria entrada', () {
      final records = [
        _punch('in', 'check_in', '2026-10-15T08:00:05.000'),
        _punch('forgot_in', 'check_out', '2026-10-15T08:00:06.000'),
        _batch('p1', 'break_start', '2026-10-15T08:00:00.000'),
      ];
      expectInAnyOrder(records, ['in', 'forgot_in', 'p1']);
    });

    test('lote antigo e pontos so do lote seguem a ordem do tipo', () {
      final records = [
        _batch('b', 'check_in', '2026-10-16T07:00:00.000'),
        _manual('l', 'check_out', '2026-10-16T07:00:00.000'),
        _batch('p', 'break_end', '2026-10-16T07:00:00.000'),
      ];
      expectInAnyOrder(records, ['p', 'l', 'b']);
    });
  });

  group('recordsBeforePunch', () {
    test('saida offline da noite no minuto da entrada do lote', () {
      // A Entrada 07:00 do lote (turno do dia) vem depois da Saida 07:00:14
      // batida offline: o turno aberto no momento dela e a noite.
      final records = [
        _punch('nin', 'check_in', '2026-10-15T19:00:12.345'),
        _batch('din', 'check_in', '2026-10-16T07:00:00.000'),
      ];
      final before = recordsBeforePunch(records, {
        'record_type': 'check_out',
        'timestamp': '2026-10-16T07:00:14.512',
      });
      expect(_ids(before), ['nin']);
      expect(openShiftCheckIn(before)?['id'], 'nin');
      // Depois do minuto, a entrada do lote conta.
      final later = recordsBeforePunch(records, {
        'record_type': 'check_out',
        'timestamp': '2026-10-16T15:00:00.000',
      });
      expect(_ids(later), ['nin', 'din']);
    });

    test('ponto do mesmo horario e tipo conta (a propria batida gravada)',
        () {
      final records = [
        _punch('in', 'check_in', '2026-10-15T08:00:00.000'),
        _punch('out', 'check_out', '2026-10-15T17:00:00'),
        _punch('later', 'check_in', '2026-10-15T19:00:00.000'),
      ];
      final before = recordsBeforePunch(records, {
        'record_type': 'check_out',
        'timestamp': '2026-10-15T17:00:00.000',
      });
      expect(_ids(before), ['in', 'out']);
    });
  });
}
