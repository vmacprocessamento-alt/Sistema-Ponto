import 'dart:convert';

import 'package:intl/intl.dart';

import 'timesheet.dart';

// Regras do modo diaria (users.daily_mode) que nao dependem de tela nem de
// servidor. Uma diaria e {'date': 'yyyy-MM-dd', 'registered_at': ...}; a
// guardada no aparelho, ainda nao enviada, vem com 'pending': true, e a
// lancada pelo admin, com 'created_by_admin': true.

/// Carga do dia padrao quando o cadastro nao tem uma valida.
const double dailyDefaultHours = 8;

/// Numero que escolhe a entrada e o almoco do dia padrao, tirado do nome e
/// da data. A mesma conta de _daily_standard_seed (backend/main.py), sem
/// passar de 2^31 (no navegador o int do Dart e um double).
int _standardSeed(String name, String day) {
  var value = 0;
  for (final byte in utf8.encode('$name|$day')) {
    value = (value * 31 + byte) % 1000003;
  }
  return value;
}

/// Sessoes (entrada, saida) do dia padrao de uma diaria no dia [day]
/// (yyyy-MM-dd): entrada 08:00 ou 08:30, 4h de manha, almoco de 1h ou 1h15
/// e o resto de [dailyHours] (a carga do cadastro; 8h sem uma valida) a
/// tarde. Mesma regra de daily_standard_sessions (backend/main.py): a Dash
/// mostra o horario da folha exportada.
List<(DateTime, DateTime)> dailyStandardSessions(
    String name, String day, Object? dailyHours) {
  var hours = dailyHours is num
      ? dailyHours.toDouble()
      : double.tryParse(dailyHours?.toString() ?? '') ?? 0;
  if (!(hours > 0 && hours <= 16)) hours = dailyDefaultHours;
  final total = (hours * 60).round();
  final seed = _standardSeed(name, day);
  final date = DateTime.parse(day);
  final start =
      DateTime(date.year, date.month, date.day, 8, seed.isOdd ? 30 : 0);
  if (total <= 240) return [(start, start.add(Duration(minutes: total)))];
  final lunch = start.add(const Duration(minutes: 240));
  final back = lunch.add(Duration(minutes: (seed ~/ 2).isOdd ? 75 : 60));
  return [(start, lunch), (back, back.add(Duration(minutes: total - 240)))];
}

/// Linha da folha (o formato de computeWorkDay) do dia padrao da diaria do
/// dia [day], com 'daily_entry': true.
Map<String, dynamic> dailyStandardWorkDay(
    String name, String day, Object? dailyHours, String? role) {
  final sessions = dailyStandardSessions(name, day, dailyHours);
  var normal = 0, extras = 0, extra50 = 0, extra100 = 0;
  for (final (start, end) in sessions) {
    final minutes = classifyWorkMinutes(start, end, role);
    normal += minutes['normal']!;
    extras += minutes['extras']!;
    extra50 += minutes['extra50']!;
    extra100 += minutes['extra100']!;
  }
  final format = DateFormat('HH:mm');
  String? column(int pair, bool end) => sessions.length > pair
      ? format.format(end ? sessions[pair].$2 : sessions[pair].$1)
      : null;
  return {
    'date': day,
    'check_in': column(0, false),
    'check_out': column(0, true),
    'break_start': column(1, false),
    'break_end': column(1, true),
    'entry_3': null,
    'exit_3': null,
    'start_date': day,
    'total_hours': (normal + extras + extra50 + extra100) / 60,
    'regular_hours': normal / 60,
    'overtime_hours': (extras + extra50 + extra100) / 60,
    'extra_50': extra50 / 60,
    'extra_100': extra100 / 60,
    'daily_entry': true,
  };
}

/// Pontos do dia padrao da diaria do dia [day] (entrada, inicio e fim do
/// almoco, saida), em ordem, para as telas que desenham batidas (linha do
/// tempo da Dash, Historico).
List<Map<String, dynamic>> dailyStandardRecords(
    String name, String day, Object? dailyHours) {
  final sessions = dailyStandardSessions(name, day, dailyHours);
  Map<String, dynamic> record(String id, String type, DateTime at) => {
        'id': 'daily_${day}_$id',
        'record_type': type,
        'timestamp': at.toIso8601String(),
        'daily_entry': true,
      };
  return [
    record('in', 'check_in', sessions.first.$1),
    if (sessions.length > 1) ...[
      record('lunch', 'break_start', sessions[0].$2),
      record('back', 'break_end', sessions[1].$1),
    ],
    record('out', 'check_out', sessions.last.$2),
  ];
}

/// Dia (yyyy-MM-dd) de [at].
String dailyDayKey(DateTime at) => DateFormat('yyyy-MM-dd').format(at);

/// Periodo da folha que contem [now]: 29 do mes anterior ate 28 do mes, o
/// mesmo do Meu Mes. A partir do dia 29 ja e o periodo do mes seguinte; o
/// DateTime normaliza o "29/02" de ano nao bissexto para 01/03.
({DateTime start, DateTime end}) dailyPeriodFor(DateTime now) {
  final month = now.day >= 29
      ? DateTime(now.year, now.month + 1)
      : DateTime(now.year, now.month);
  return (
    start: DateTime(month.year, month.month - 1, 29),
    end: DateTime(month.year, month.month, 28),
  );
}

/// Diarias de [entries] de [start] a [end] (dias, inclusive).
List<Map<String, dynamic>> dailyEntriesBetween(
    Iterable<Map<String, dynamic>> entries, DateTime start, DateTime end) {
  final from = dailyDayKey(start);
  final to = dailyDayKey(end);
  return entries.where((entry) {
    final day = entry['date']?.toString() ?? '';
    return day.compareTo(from) >= 0 && day.compareTo(to) <= 0;
  }).toList();
}

/// As diarias do servidor e as guardadas no aparelho que ele ainda nao tem
/// (marcadas com 'pending'), uma por dia e em ordem de data. No mesmo dia
/// vale a do servidor: a guardada ja chegou la.
List<Map<String, dynamic>> mergeDailyEntries(
    Iterable<Map<String, dynamic>> server,
    Iterable<Map<String, dynamic>> pending) {
  final byDay = <String, Map<String, dynamic>>{};
  for (final entry in pending) {
    final day = entry['date']?.toString() ?? '';
    if (day.isNotEmpty) byDay[day] = {...entry, 'pending': true};
  }
  for (final entry in server) {
    final day = entry['date']?.toString() ?? '';
    if (day.isNotEmpty) byDay[day] = entry;
  }
  return byDay.values.toList()
    ..sort((a, b) => a['date'].toString().compareTo(b['date'].toString()));
}

/// A diaria do dia de [now] em [entries], ou null.
Map<String, dynamic>? dailyEntryOn(
    Iterable<Map<String, dynamic>> entries, DateTime now) {
  final day = dailyDayKey(now);
  for (final entry in entries) {
    if (entry['date'] == day) return entry;
  }
  return null;
}
