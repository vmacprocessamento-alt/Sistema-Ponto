import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/daily_entries.dart';

Map<String, dynamic> _entry(String date, {String? at}) =>
    {'date': date, if (at != null) 'registered_at': at};

void main() {
  group('dailyPeriodFor', () {
    test('ate o dia 28 e o periodo do proprio mes', () {
      final period = dailyPeriodFor(DateTime(2026, 10, 17, 9));
      expect(period.start, DateTime(2026, 9, 29));
      expect(period.end, DateTime(2026, 10, 28));
    });

    test('do dia 29 em diante ja e o periodo do mes seguinte', () {
      final period = dailyPeriodFor(DateTime(2026, 10, 29));
      expect(period.start, DateTime(2026, 10, 29));
      expect(period.end, DateTime(2026, 11, 28));
    });

    test('virada do ano e fevereiro sem dia 29', () {
      final december = dailyPeriodFor(DateTime(2026, 12, 30));
      expect(december.start, DateTime(2026, 12, 29));
      expect(december.end, DateTime(2027, 1, 28));
      // 29/02/2027 nao existe: o periodo de marco comeca em 01/03.
      expect(dailyPeriodFor(DateTime(2027, 3, 10)).start, DateTime(2027, 3, 1));
    });
  });

  test('dailyEntriesBetween fica com os dias do periodo, inclusive', () {
    final entries = [
      _entry('2026-09-28'),
      _entry('2026-09-29'),
      _entry('2026-10-28'),
      _entry('2026-10-29'),
    ];
    final inside = dailyEntriesBetween(
        entries, DateTime(2026, 9, 29), DateTime(2026, 10, 28, 23, 59));
    expect(inside.map((e) => e['date']), ['2026-09-29', '2026-10-28']);
  });

  test('mergeDailyEntries: uma por dia, a do servidor vence a guardada', () {
    final merged = mergeDailyEntries(
      [_entry('2026-10-02', at: '2026-10-02T08:01:00')],
      [
        _entry('2026-10-02', at: '2026-10-02T08:00:00'),
        _entry('2026-10-01', at: '2026-10-01T07:50:00'),
      ],
    );
    expect(merged.map((e) => e['date']), ['2026-10-01', '2026-10-02']);
    expect(merged.first['pending'], isTrue);
    expect(merged.last['pending'], isNull);
    expect(merged.last['registered_at'], '2026-10-02T08:01:00');
  });

  group('dia padrao da diaria', () {
    String hhmm(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    // Os mesmos casos de DailyStandardDayTest (backend/test_work_schedule.py):
    // a Dash mostra o horario da folha exportada.
    test('mesmos horarios do backend', () {
      final cases = <(String, String, num, List<(String, String)>)>[
        ('Diarista Teste', '2026-10-01', 8, [('08:00', '12:00'), ('13:00', '17:00')]),
        ('José Ação', '2026-10-17', 8, [('08:00', '12:00'), ('13:15', '17:15')]),
        ('José Ação', '2026-10-18', 7.5, [('08:30', '12:30'), ('13:45', '17:15')]),
        ('Ana', '2026-10-19', 4, [('08:30', '12:30')]),
      ];
      for (final (name, day, hours, expected) in cases) {
        final sessions = dailyStandardSessions(name, day, hours);
        expect([for (final s in sessions) (hhmm(s.$1), hhmm(s.$2))], expected,
            reason: '$name $day');
      }
    });

    test('carga invalida vira 8h', () {
      for (final hours in [null, 0, 30, 'abc']) {
        final sessions = dailyStandardSessions('Ana', '2026-10-19', hours);
        final minutes = sessions.fold<int>(
            0, (sum, s) => sum + s.$2.difference(s.$1).inMinutes);
        expect(minutes, 480, reason: '$hours');
      }
      // Texto numerico (cadastro antigo) vale.
      final sessions = dailyStandardSessions('Ana', '2026-10-19', '6');
      expect(sessions.fold<int>(
              0, (sum, s) => sum + s.$2.difference(s.$1).inMinutes),
          360);
    });

    test('linha da folha no formato de computeWorkDay', () {
      final day = dailyStandardWorkDay(
          'Diarista Teste', '2026-10-01', 8, 'employee');
      expect(day['check_in'], '08:00');
      expect(day['check_out'], '12:00');
      expect(day['break_start'], '13:00');
      expect(day['break_end'], '17:00');
      expect(day['total_hours'], 8.0);
      expect(day['regular_hours'], 8.0);
      expect(day['daily_entry'], isTrue);
      // Domingo paga 100%, como qualquer dia da folha.
      final sunday = dailyStandardWorkDay('Ana', '2026-10-18', 8, 'employee');
      expect(sunday['extra_100'], 8.0);
      expect(sunday['regular_hours'], 0.0);
    });

    test('pontos do dia padrao para a linha do tempo e o historico', () {
      final records =
          dailyStandardRecords('Diarista Teste', '2026-10-01', 8);
      expect([for (final r in records) r['record_type']],
          ['check_in', 'break_start', 'break_end', 'check_out']);
      expect([
        for (final r in records) hhmm(DateTime.parse(r['timestamp'] as String))
      ], ['08:00', '12:00', '13:00', '17:00']);
      expect(dailyStandardRecords('Ana', '2026-10-19', 4).length, 2);
    });
  });

  test('dailyEntryOn acha a diaria do dia', () {
    final entries = [_entry('2026-10-16'), _entry('2026-10-17')];
    expect(dailyEntryOn(entries, DateTime(2026, 10, 17, 23, 59))?['date'],
        '2026-10-17');
    expect(dailyEntryOn(entries, DateTime(2026, 10, 18, 0, 1)), isNull);
  });
}
