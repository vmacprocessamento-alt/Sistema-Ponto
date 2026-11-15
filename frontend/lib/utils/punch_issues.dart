import 'package:intl/intl.dart';

import 'shift_records.dart';
import 'timesheet.dart' show isAutomaticBreakEnd, isHoliday;

/// ABA PENDENCIAS DA GESTAO (15/11/2026). O gestor quer saber se o ponto esta
/// certo ou se a equipe esta deixando de bater, principalmente de um dia para
/// o outro. Aqui sai, por pessoa, o que a folha nao consegue pagar direito
/// sem o gestor olhar:
///   - turno sem saida (entrada esquecida aberta, ou outra entrada depois);
///   - saida do "Esqueci" sem o horario real lancado (turno de 0h);
///   - pausa sem retorno (o sistema fechou com 1h);
///   - batida solta (pausa ou saida sem entrada);
///   - jornada de mais de 16h (deslocamento ou esquecimento?);
///   - dia util sem nenhuma batida (falta, folga, atestado ou esqueceu?).
/// Os turnos seguem o agrupamento da folha (groupRecordsByWorkDay): o turno
/// da noite fica no dia da entrada. Dia com o lote antigo do gestor nao entra
/// (ele grava a noite numa data so; a folha ja trata).
enum PunchIssueKind {
  openShift,
  forgottenExit,
  autoBreakReturn,
  loosePunch,
  longShift,
  missingDay,
}

class PunchIssue {
  const PunchIssue(
    this.kind,
    this.at,
    this.text, {
    this.record,
    this.entry,
    this.pause,
    this.notBefore,
    this.notAfter,
  });

  final PunchIssueKind kind;

  /// Dia (e hora, quando ha) a que a pendencia se refere.
  final DateTime at;
  final String text;

  /// O ponto a corrigir: a saida do "Esqueci", o retorno automatico, a batida
  /// solta ou a saida da jornada longa.
  final Map<String, dynamic>? record;

  /// A entrada do turno (turno sem saida, "Esqueci", jornada longa, pausa).
  final Map<String, dynamic>? entry;

  /// O inicio da pausa sem retorno.
  final Map<String, dynamic>? pause;

  /// Janela da correcao: a hora certa fica depois de [notBefore] e antes de
  /// [notAfter] (a proxima entrada, a saida do turno ou agora).
  final DateTime? notBefore;
  final DateTime? notAfter;
}

/// Nome curto do tipo, para os resumos.
String punchIssueLabel(PunchIssueKind kind) {
  switch (kind) {
    case PunchIssueKind.openShift:
      return 'Turno sem saída';
    case PunchIssueKind.forgottenExit:
      return '"Esqueci" sem horário';
    case PunchIssueKind.autoBreakReturn:
      return 'Pausa sem retorno';
    case PunchIssueKind.loosePunch:
      return 'Batida solta';
    case PunchIssueKind.longShift:
      return 'Jornada > 16h';
    case PunchIssueKind.missingDay:
      return 'Dia útil sem ponto';
  }
}

const Set<String> _pauseStarts = {'break_start', 'entry_3'};
const Map<String, String> _pauseEndOf = {
  'break_start': 'break_end',
  'entry_3': 'exit_3',
};

final DateFormat _dayHour = DateFormat('dd/MM HH:mm');
final DateFormat _hour = DateFormat('HH:mm');

DateTime? _at(Map<String, dynamic> record) =>
    DateTime.tryParse(record['timestamp']?.toString() ?? '');

DateTime _dateOnly(DateTime moment) =>
    DateTime(moment.year, moment.month, moment.day);

String _span(Duration duration) =>
    '${duration.inHours}h${(duration.inMinutes % 60).toString().padLeft(2, '0')}';

/// Pendencias dos pontos [records] de UMA pessoa, nos dias de [from] (meia
/// noite) ate [now]. [records] pode trazer pontos de antes de [from] (o turno
/// que comecou antes); so entram as pendencias de [from] em diante.
///
/// [checkMissingDays]: confere os dias uteis (segunda a sexta, menos feriado
/// nacional) sem nenhuma batida, de [from] (ou [activeSince], se depois) ate
/// ontem. Desligue para quem nao bate ponto (modo diaria, gestor que nao bate).
List<PunchIssue> findPunchIssues(
  Iterable<Map<String, dynamic>> records, {
  required DateTime from,
  required DateTime now,
  bool checkMissingDays = true,
  DateTime? activeSince,
}) {
  final start = _dateOnly(from);
  final issues = <PunchIssue>[];
  void add(
    PunchIssueKind kind,
    DateTime at,
    String text, {
    Map<String, dynamic>? record,
    Map<String, dynamic>? entry,
    Map<String, dynamic>? pause,
    DateTime? notBefore,
    DateTime? notAfter,
  }) {
    if (at.isBefore(start)) return;
    issues.add(PunchIssue(kind, at, text,
        record: record,
        entry: entry,
        pause: pause,
        notBefore: notBefore,
        notAfter: notAfter));
  }

  // Entradas da pessoa, em ordem: a saida que falta fica antes da proxima.
  final entryTimes = [
    for (final record in records)
      if (record['record_type'] == 'check_in')
        if (_at(record) case final at?) at,
  ]..sort();
  DateTime nextEntryOrNow(DateTime after) =>
      entryTimes.firstWhere((at) => at.isAfter(after), orElse: () => now);

  final grouped = groupRecordsByWorkDay(records);
  final dayKeys = grouped.keys.toList()..sort();
  for (var d = 0; d < dayKeys.length; d++) {
    final ordered = sortRecords(grouped[dayKeys[d]]!);
    if (ordered.any(isLegacyBatchRecord)) continue;
    final isLastDay = d == dayKeys.length - 1;

    Map<String, dynamic>? open;
    DateTime? openAt;
    Map<String, dynamic>? pause;
    var hadShift = false;
    for (var i = 0; i < ordered.length; i++) {
      final record = ordered[i];
      final at = _at(record);
      if (at == null) continue;
      final type = record['record_type']?.toString() ?? '';
      if (type == 'check_in') {
        if (open != null && openAt != null) {
          add(PunchIssueKind.openShift, openAt,
              'Entrada de ${_dayHour.format(openAt)} sem saída: depois veio '
              'outra entrada (${_dayHour.format(at)}).',
              entry: open, notBefore: openAt, notAfter: at);
        }
        open = record;
        openAt = at;
        pause = null;
        hadShift = true;
      } else if (_pauseStarts.contains(type)) {
        if (open == null) {
          add(PunchIssueKind.loosePunch, at,
              'Início de pausa às ${_dayHour.format(at)} sem turno aberto.',
              record: record);
        } else {
          pause ??= record;
        }
      } else if (_pauseEndOf.containsValue(type)) {
        if (open == null) {
          if (!isAutomaticBreakEnd(record)) {
            add(PunchIssueKind.loosePunch, at,
                'Retorno de pausa às ${_dayHour.format(at)} sem turno aberto.',
                record: record);
          }
          continue;
        }
        final started = pause;
        if (started == null || _pauseEndOf[started['record_type']] != type) {
          continue;
        }
        // O gestor ja ajustou (editou) ou conferiu esse retorno: esta certo.
        if (isAutomaticBreakEnd(record) &&
            record['edited_by_admin'] != true &&
            record['reviewed_at'] == null &&
            !_realReturnFollows(ordered, i, type)) {
          final pauseAt = _at(started) ?? at;
          add(PunchIssueKind.autoBreakReturn, pauseAt,
              'Pausa de ${_dayHour.format(pauseAt)} sem retorno: o sistema '
              'fechou com 1h.',
              record: record,
              entry: open,
              pause: started,
              notBefore: pauseAt,
              notAfter: _nextMarkAfter(ordered, i) ?? nextEntryOrNow(at));
        }
        pause = null;
      } else if (type == 'check_out') {
        final entry = open;
        final entryAt = openAt;
        if (entry == null || entryAt == null) {
          // Saida repetida depois de um turno fechado e a correcao do gestor
          // (vale a ultima); sem turno nenhum antes, e solta.
          if (!hadShift) {
            add(PunchIssueKind.loosePunch, at,
                'Saída às ${_dayHour.format(at)} sem entrada.',
                record: record);
          }
          continue;
        }
        final span = at.difference(entryAt);
        if (span < const Duration(minutes: 1)) {
          if (!_laterExitFollows(ordered, i)) {
            add(PunchIssueKind.forgottenExit, entryAt,
                'Turno de ${_dayHour.format(entryAt)} fechado no "Esqueci" '
                '(0h): falta lançar o horário real da saída.',
                record: record,
                entry: entry,
                notBefore: entryAt,
                notAfter: nextEntryOrNow(entryAt));
          }
        } else if (span > maxShiftSpan &&
            record['reviewed_at'] == null &&
            (span > const Duration(hours: 24) ||
                (record['edited_by_admin'] != true &&
                    record['created_by_admin'] != true))) {
          // Saida que o gestor lancou, corrigiu ou conferiu ja foi olhada; a
          // de mais de 24h aparece mesmo assim (data trocada na correcao?).
          add(PunchIssueKind.longShift, entryAt,
              'Jornada de ${_span(span)}: entrada ${_dayHour.format(entryAt)}, '
              'saída ${_dayHour.format(at)}. Deslocamento ou esqueceu a saída?',
              record: record,
              entry: entry,
              notBefore: entryAt,
              notAfter: nextEntryOrNow(at));
        }
        if (pause != null) {
          final pauseAt = _at(pause);
          if (pauseAt != null) {
            add(PunchIssueKind.autoBreakReturn, pauseAt,
                'Pausa de ${_dayHour.format(pauseAt)} sem retorno até a saída '
                '(${_hour.format(at)}).',
                entry: entry,
                pause: pause,
                notBefore: pauseAt,
                notAfter: at);
          }
        }
        open = null;
        openAt = null;
        pause = null;
      }
    }
    if (open != null && openAt != null) {
      final openFor = now.difference(openAt);
      // O turno de agora, ainda dentro de 16h, e so alguem trabalhando.
      if (!isLastDay || openFor > maxShiftSpan) {
        add(
            PunchIssueKind.openShift,
            openAt,
            isLastDay
                ? 'Turno aberto desde ${_dayHour.format(openAt)} (há '
                    '${_span(openFor)}): ainda trabalhando ou esqueceu a saída?'
                : 'Entrada de ${_dayHour.format(openAt)} sem saída.',
            entry: open,
            notBefore: openAt,
            notAfter: nextEntryOrNow(openAt));
      }
    }
  }

  if (checkMissingDays) {
    final punchedDays = <DateTime>{
      for (final record in records)
        if (_at(record) case final at?) _dateOnly(at),
      for (final key in grouped.keys)
        if (DateTime.tryParse(key) case final day?) _dateOnly(day),
    };
    var day = start;
    final since = activeSince == null ? null : _dateOnly(activeSince);
    if (since != null && since.isAfter(day)) day = since;
    final today = _dateOnly(now);
    for (; day.isBefore(today); day = DateTime(day.year, day.month, day.day + 1)) {
      if (day.weekday > DateTime.friday || isHoliday(day)) continue;
      if (punchedDays.contains(day)) continue;
      add(PunchIssueKind.missingDay, day,
          '${DateFormat('dd/MM').format(day)}: nenhuma batida neste dia útil '
          '(falta, folga, atestado ou esqueceu?).');
    }
  }

  issues.sort((a, b) => a.at.compareTo(b.at));
  return issues;
}

/// Depois do retorno automatico em [index], vem o retorno batido da mesma
/// pausa (ponto offline que chegou tarde)? Entao vale o batido.
bool _realReturnFollows(
    List<Map<String, dynamic>> ordered, int index, String type) {
  for (var j = index + 1; j < ordered.length; j++) {
    final next = ordered[j]['record_type']?.toString();
    if (next == 'check_in' || next == 'check_out' || _pauseStarts.contains(next)) {
      return false;
    }
    if (next == type && !isAutomaticBreakEnd(ordered[j])) return true;
  }
  return false;
}

/// Hora do proximo ponto que fecha a pausa de [index] por fora: saida,
/// entrada ou outro inicio de pausa. Null se nao houver no dia.
DateTime? _nextMarkAfter(List<Map<String, dynamic>> ordered, int index) {
  for (var j = index + 1; j < ordered.length; j++) {
    final next = ordered[j]['record_type']?.toString();
    if (next == 'check_in' || next == 'check_out' || _pauseStarts.contains(next)) {
      return _at(ordered[j]);
    }
  }
  return null;
}

/// Depois da saida em [index], antes de outra entrada, vem outra saida (o
/// gestor lancando a saida real do "Esqueci")?
bool _laterExitFollows(List<Map<String, dynamic>> ordered, int index) {
  for (var j = index + 1; j < ordered.length; j++) {
    final next = ordered[j]['record_type']?.toString();
    if (next == 'check_in') return false;
    if (next == 'check_out') return true;
  }
  return false;
}
