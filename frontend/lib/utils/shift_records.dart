// Regras de turno sobre os pontos (time_records) de um usuario.
//
// Um turno vai de uma entrada (check_in) ate a saida (check_out) seguinte e
// pode atravessar a meia-noite: quem entra 19:30 e sai 07:00 trabalhou um
// turno so, que pertence ao dia em que comecou.

/// Maior distancia entre a entrada e um ponto do dia seguinte nas regras que
/// ADIVINHAM o turno a partir dos lancamentos do gestor (noite do lote antigo,
/// saida repetida que corrige o turno, volta da refeicao) e no aviso do lote.
///
/// JORNADA SEM LIMITE (09/11/2026): o ponto ligado ao turno aberto
/// ([belongsToShift]) e dele, mesmo passando de 16h (deslocamento que
/// atravessa a noite). Antes, passou de 16h, a saida caia solta no dia
/// seguinte e o app so deixava "Fechar sem horas". A pessoa escolhe no aviso
/// do turno aberto se trabalhou ate agora ou se esqueceu, e a jornada acima de
/// 16h aparece na Conferencia da Gestao (long_shift_minutes). Ponto antigo,
/// sem a ligacao, segue a regra das 16h: a folha de meses ja fechados nao muda
/// (a entrada 08:00 esquecida e a saida 07:50 do dia seguinte nao viram 24h).
const Duration maxShiftSpan = Duration(hours: 16);

/// O ponto [record] e do turno aberto pela entrada [entryId]? O servidor grava
/// shift_entry_id em toda batida feita com turno aberto (09/11/2026), e o lote
/// do gestor tambem; a saida do "Esqueci" tem o id forgot_<entrada> (o gestor
/// corrige o horario nela).
bool belongsToShift(Map<dynamic, dynamic> record, String? entryId) {
  if (entryId == null || entryId.isEmpty) return false;
  return record['shift_entry_id']?.toString() == entryId ||
      record['id']?.toString() == 'forgot_$entryId';
}

/// Intervalo entre dois turnos que conta como refeicao: ate 2h, o maximo do
/// intervalo de refeicao da CLT. Quem bate saida 11:00 e entrada 12:00 ja
/// almocou; o almoco automatico do segundo turno tirava mais 1h.
const Duration maxMealGap = Duration(hours: 2);

/// Ordem dos tipos de ponto no MESMO timestamp: fim da pausa, saida, entrada
/// e inicio da pausa. O lote do gestor grava os horarios sem segundos, entao
/// a Pausa 1 fim 07:00 e a Saida 07:00 saem com o mesmo timestamp; sem
/// desempate a ordem vinha do id aleatorio do Firestore (ou do sort instavel
/// do Dart, acima de 32 pontos) e a noite pagava 6,5h ou 10,5h.
///   - o fim da pausa antes da saida fecha a pausa dentro do turno;
///   - a saida antes da entrada fecha um turno antes de abrir o seguinte
///     (noite 19:00-07:00 e dia 07:00-15:00 lancados no lote): ao contrario,
///     a saida 07:00 fechava o turno do dia no "Esqueci" e a noite ficava
///     aberta;
///   - a entrada antes do inicio da pausa (Entrada e Pausa inicio 19:30).
/// O inicio da pausa no horario da saida fica depois dela, fora do turno.
/// Mesma ordem do backend (_record_sort_key). O ponto do lote no mesmo
/// minuto de uma batida com segundos segue a mesma ordem (sortRecords).
const Map<String, int> _sameTimestampRank = {
  'break_end': 0,
  'exit_3': 0,
  'check_out': 1,
  'check_in': 2,
  'break_start': 3,
  'entry_3': 3,
};

int _rankAtSameTimestamp(Map<dynamic, dynamic> record) =>
    _sameTimestampRank[record['record_type']?.toString()] ??
    _sameTimestampRank.length;

final RegExp _timestampPattern =
    RegExp(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(?::(\d{2})(?:\.(\d+))?)?(.*)$');

/// Timestamp com segundos e a fracao em 6 digitos: "...19:30:00" (backend,
/// isoformat sem microssegundos) e "...19:30:00.000" (app e lote) sao o mesmo
/// instante. Comparando o texto cru, o mais curto vinha antes e o desempate
/// pelo tipo nunca rodava: o fim da pausa do lote igual a saida do FECHAR
/// PONTO caia depois dela e sumia. Mesma regra do backend
/// (_normalized_timestamp).
String _normalizedTimestamp(Object? value) {
  final raw = value?.toString() ?? '';
  final match = _timestampPattern.firstMatch(raw);
  if (match == null) return raw;
  final fraction = (match[3] ?? '').padRight(6, '0').substring(0, 6);
  return '${match[1]}:${match[2] ?? '00'}.$fraction${match[4]}';
}

/// Chave de ordem de um ponto: o instante, se vai logo depois de outro ponto
/// do mesmo minuto (o do lote, em sortRecords), o tipo
/// ([_sameTimestampRank]) e, por ultimo, o id, para a ordem nao depender da
/// ordem da lista.
class _RecordKey implements Comparable<_RecordKey> {
  const _RecordKey(this.at, this.rank, this.id, {this.afterAt = false});

  final String at;
  final bool afterAt;
  final int rank;
  final String id;

  @override
  int compareTo(_RecordKey other) {
    final byTime = at.compareTo(other.at);
    if (byTime != 0) return byTime;
    if (afterAt != other.afterAt) return afterAt ? 1 : -1;
    final byType = rank.compareTo(other.rank);
    if (byType != 0) return byType;
    return id.compareTo(other.id);
  }
}

_RecordKey _ownKey(Map<dynamic, dynamic> record) => _RecordKey(
      _normalizedTimestamp(record['timestamp']),
      _rankAtSameTimestamp(record),
      record['id']?.toString() ?? '',
    );

/// Ordem cronologica de dois pontos: o instante e, no mesmo instante, o tipo
/// e o id ([_RecordKey]). Nao ve os outros pontos da lista: para uma
/// lista de pontos que vira turno ou folha, use sortRecords, que tambem
/// encaixa o ponto do lote no minuto de uma batida com segundos.
int compareRecords(Map<dynamic, dynamic> a, Map<dynamic, dynamic> b) =>
    _ownKey(a).compareTo(_ownKey(b));

/// Ponto do lote novo num minuto cheio (o lote grava HH:mm:00.000).
bool _isWholeMinuteBatch(Map<dynamic, dynamic> record, _RecordKey key) =>
    record[batchRealDatesField] == true &&
    key.at.length >= 26 &&
    key.at.substring(16, 26) == ':00.000000';

/// Indices de [records] em ordem cronologica.
///
/// O lote do gestor grava so hora e minuto; a batida do app e a do backend
/// tem segundos. O ponto do lote vale pelo minuto inteiro: ele vai logo
/// depois da ultima batida do mesmo usuario no mesmo minuto com tipo antes do
/// dele (_sameTimestampRank) e, sem nenhuma, no comeco do minuto. Pelo
/// horario cru, a Entrada 07:00 do lote vinha antes da Saida 07:00:14 do app
/// da noite anterior: a saida virava o "Esqueci" do dia e a noite perdia
/// todas as horas (e o turno do dia nao aparecia aberto). Do mesmo jeito, a
/// Saida 07:00 do lote fica depois da Pausa fim 07:00:20 do app e antes da
/// Entrada 07:00:20 do turno seguinte. Entre pontos do lote, e entre batidas
/// do app, nada muda (a batida do app nunca e arredondada para o minuto: a
/// saida do "Esqueci", 1s depois da entrada, ficaria antes dela).
/// Mesma regra do backend (_sort_records).
List<int> chronologicalOrder(List<Map<dynamic, dynamic>> records) {
  final own = [for (final record in records) _ownKey(record)];
  // Usuario e minuto (yyyy-MM-ddTHH:mm) do ponto.
  String minuteOf(int i) {
    final at = own[i].at;
    return '${records[i]['user_id'] ?? ''}|'
        '${at.length >= 16 ? at.substring(0, 16) : at}';
  }

  final punchesByMinute = <String, List<int>>{};
  for (var i = 0; i < records.length; i++) {
    if (!_isWholeMinuteBatch(records[i], own[i])) {
      punchesByMinute.putIfAbsent(minuteOf(i), () => []).add(i);
    }
  }
  final keys = [
    for (var i = 0; i < records.length; i++)
      if (_isWholeMinuteBatch(records[i], own[i]))
        _placedBatchKey(own, i, punchesByMinute[minuteOf(i)] ?? const [])
      else
        own[i],
  ];
  return List<int>.generate(records.length, (i) => i)
    ..sort((a, b) {
      final byKey = keys[a].compareTo(keys[b]);
      return byKey != 0 ? byKey : a.compareTo(b);
    });
}

/// Chave do ponto do lote [index]: logo depois da ultima batida de
/// [sameMinute] com tipo antes do dele, ou a propria chave.
_RecordKey _placedBatchKey(
    List<_RecordKey> own, int index, List<int> sameMinute) {
  final key = own[index];
  _RecordKey? latest;
  for (final j in sameMinute) {
    if (own[j].rank < key.rank &&
        (latest == null || own[j].compareTo(latest) > 0)) {
      latest = own[j];
    }
  }
  return latest == null
      ? key
      : _RecordKey(latest.at, key.rank, key.id, afterAt: true);
}

/// Ordena [records] no lugar (chronologicalOrder) e devolve a propria lista.
/// Toda lista de pontos que vira turno ou folha ordena por aqui.
List<T> sortRecords<T extends Map<dynamic, dynamic>>(List<T> records) {
  final order = chronologicalOrder(records);
  final sorted = [for (final i in order) records[i]];
  records.setAll(0, sorted);
  return records;
}

/// Id da batida em recordsBeforePunch: depois de qualquer id do Firestore.
const String _afterEveryId = '\u{10FFFF}';

/// Pontos de [records] (de um usuario) que vem antes da batida [punch]
/// (user_id, record_type e timestamp), em ordem (sortRecords): o turno
/// aberto no momento da batida offline, que chega depois. Pelo texto do
/// horario, a Entrada 07:00 do lote do turno do dia ficava antes da Saida
/// 07:00:14 da noite batida offline, e a saida fechava o turno do dia. Os
/// pontos do mesmo horario e tipo da batida contam (pode ser ela mesma, ja
/// gravada). Mesma regra do backend (_records_before_punch).
List<Map<String, dynamic>> recordsBeforePunch(
    Iterable<Map<String, dynamic>> records, Map<String, dynamic> punch) {
  final all = [
    ...records,
    {...punch, 'id': _afterEveryId},
  ];
  final order = chronologicalOrder(all);
  final at = order.indexOf(all.length - 1);
  return [for (final i in order.take(at)) all[i]];
}

List<Map<String, dynamic>> _chronological(Iterable<dynamic> records) =>
    sortRecords(records
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList());

String _dayOf(Map<String, dynamic> record) =>
    record['timestamp'].toString().substring(0, 10);

/// Campo que o lote do gestor grava em todo ponto que ja sai com a data real
/// (batch_entry.dart): a saida 07:00 da noite iniciada as 19:30 fica no dia
/// seguinte, como no app.
const String batchRealDatesField = 'batch_real_dates';

/// Ponto do lote ANTIGO do gestor: lancado para outra pessoa
/// (created_by_admin) sem [batchRealDatesField]. Esse lote gravava todos os
/// horarios na data escolhida, entao a noite 19:30-07:00 ficava com a saida
/// ANTES da entrada, no mesmo dia. So esses pontos passam pelas regras da
/// noite do lote (manualNightExitIndex, manualNightMorning); o lote novo vale
/// pelo horario real, como a batida do app. Mesma regra do backend
/// (_is_legacy_batch).
bool isLegacyBatchRecord(Map<String, dynamic> record) =>
    record['created_by_admin'] == true && record[batchRealDatesField] != true;

const Set<String> _pauseTypes = {
  'break_start',
  'break_end',
  'entry_3',
  'exit_3'
};

/// Turno da noite lancado no lote ANTIGO do gestor (isLegacyBatchRecord). O
/// lote antigo gravava todos os horarios na data escolhida, entao entrada
/// 19:30 e saida 07:00 ficam com a saida ANTES da entrada, no mesmo dia (o
/// calculo do dia vira a saida para a manha seguinte). E a ultima entrada do
/// dia, do lote antigo, sem saida depois dela, e com uma saida do lote antigo
/// antes da PRIMEIRA entrada do dia. Ja vem fechada. Os pontos do lote novo
/// (com a data real) e do app nunca entram aqui: nem como entrada, nem como
/// saida ou pausa da noite.
///
/// As saidas depois da primeira entrada fecham os turnos do proprio dia: na
/// dobra 08-17 e 19:30-07:00, a saida 17:00 virava a saida da noite (turno de
/// 21h30) e a noite inteira se perdia quando o 08-17 era do app. Com mais de
/// uma saida do lote antigo antes da primeira entrada, a da noite e a mais
/// perto dela; as anteriores seguem a regra comum e fecham o turno aberto da
/// vespera (a saida real lancada para corrigir o "Esqueci").
///
/// Sem saida do lote antigo antes da primeira entrada, vale a saida do lote
/// antigo depois dela que outra saida substitui antes da proxima entrada (a
/// mais perto da entrada da noite). Na dobra 06:50-16:00 e 19:00-07:00, a saida
/// 07:00 da noite cai depois da entrada 06:50: a noite inteira se perdia e a
/// entrada 19:00 ficava aberta. O turno do dia ja ignora essa saida (saida
/// repetida, vale a ultima), entao reserva-la para a noite nao muda o dia.
///
/// A noite vai no maximo [maxShiftSpan] da entrada ate a saida do dia
/// seguinte: a entrada 08:00 lancada pelo gestor no dia da saida 07:00 que
/// corrige o "Esqueci" da vespera virava uma noite de 23h; ela e o turno do
/// dia, aberto, e a saida 07:00 fecha a vespera.
///
/// Devolve o indice dessa saida em [ordered] (cronologico) quando a entrada
/// em [index] e desse tipo, ou null.
int? manualNightExitIndex(List<Map<String, dynamic>> ordered, int index) {
  final entry = ordered[index];
  if (entry['record_type'] != 'check_in' || !isLegacyBatchRecord(entry)) {
    return null;
  }
  final day = _dayOf(entry);
  for (var j = index + 1;
      j < ordered.length && _dayOf(ordered[j]) == day;
      j++) {
    final type = ordered[j]['record_type'];
    if (type == 'check_in' || type == 'check_out') return null;
  }
  final entryAt = DateTime.tryParse(entry['timestamp'].toString());
  bool fitsNight(int exit) {
    final exitAt = DateTime.tryParse(ordered[exit]['timestamp'].toString());
    return entryAt != null &&
        exitAt != null &&
        exitAt.add(const Duration(days: 1)).difference(entryAt) <=
            maxShiftSpan;
  }

  final firstCheckIn = _firstCheckInOfDay(ordered, index);
  for (var j = firstCheckIn - 1; j >= 0 && _dayOf(ordered[j]) == day; j--) {
    if (_isLegacyBatchCheckOut(ordered[j])) {
      if (fitsNight(j)) return j;
      break;
    }
  }
  for (var j = index - 1; j > firstCheckIn; j--) {
    if (_isLegacyBatchCheckOut(ordered[j]) && _isSupersededExit(ordered, j)) {
      return fitsNight(j) ? j : null;
    }
  }
  return null;
}

bool _isLegacyBatchCheckOut(Map<String, dynamic> record) =>
    record['record_type'] == 'check_out' && isLegacyBatchRecord(record);

/// Indice da primeira entrada da data da entrada em [index].
int _firstCheckInOfDay(List<Map<String, dynamic>> ordered, int index) {
  final day = _dayOf(ordered[index]);
  var first = index;
  for (var j = index - 1; j >= 0 && _dayOf(ordered[j]) == day; j--) {
    if (ordered[j]['record_type'] == 'check_in') first = j;
  }
  return first;
}

/// A saida em [index] e seguida por outra saida antes da proxima entrada?
bool _isSupersededExit(List<Map<String, dynamic>> ordered, int index) {
  for (var j = index + 1; j < ordered.length; j++) {
    final type = ordered[j]['record_type'];
    if (type == 'check_in') return false;
    if (type == 'check_out') return true;
  }
  return false;
}

bool _isLegacyBatchNightEntry(
        List<Map<String, dynamic>> ordered, int index) =>
    manualNightExitIndex(ordered, index) != null;

/// Pontos da manha seguinte do turno da noite do lote antigo cuja entrada
/// esta em [index], em ordem: as pausas do lote antigo gravadas antes da
/// saida reservada (desde a saida anterior do dia) e a propria saida, por
/// ultimo. Vazio se a entrada nao e desse tipo.
///
/// Saida reservada depois da primeira entrada do dia (dobra 06:50-16:00 e
/// 19:00-07:00): as pausas da madrugada ficam antes dessa entrada; as que
/// estao entre ela e a saida sao do turno do dia.
///
/// So uma saida do lote antigo encerra a busca: a do app ou do lote novo no
/// meio (a noite do app da vespera fechando 07:00, antes da saida 07:25 do
/// lote) nao e desse lote, que gravava todo horario na data dele. Parando
/// nela, a Pausa 2 03:00-03:30 da noite do lote ia para a noite do app:
/// tirava o jantar automatico dela e sumia da noite do lote (1h a mais).
/// Entrada nao ha nesse trecho: ele fica antes da primeira entrada do dia.
List<int> manualNightMorning(List<Map<String, dynamic>> ordered, int index) {
  final exit = manualNightExitIndex(ordered, index);
  if (exit == null) return const [];
  final day = _dayOf(ordered[exit]);
  final firstCheckIn = _firstCheckInOfDay(ordered, index);
  final from = exit > firstCheckIn ? firstCheckIn - 1 : exit - 1;
  final pauses = <int>[];
  for (var j = from; j >= 0 && _dayOf(ordered[j]) == day; j--) {
    final record = ordered[j];
    if (!isLegacyBatchRecord(record)) continue;
    final type = record['record_type'];
    if (type == 'check_in' || type == 'check_out') break;
    if (_pauseTypes.contains(type)) pauses.add(j);
  }
  return [...pauses.reversed, exit];
}

/// Todos os pontos de [ordered] que sao da manha seguinte por um turno da
/// noite do lote antigo (manualNightMorning de cada entrada).
Set<int> allManualNightMorning(List<Map<String, dynamic>> ordered) => {
      for (var i = 0; i < ordered.length; i++)
        ...manualNightMorning(ordered, i),
    };

/// Entrada do turno que continua aberto (a ultima entrada sem saida depois
/// dela), ou null. Mesma regra do backend (_open_shift_start), mais o turno da
/// noite do lote antigo do gestor, que ja vem fechado. O lote novo grava a
/// saida da noite no dia seguinte e fecha o turno como a saida do app.
Map<String, dynamic>? openShiftCheckIn(Iterable<dynamic> records) {
  final ordered = _chronological(records);
  Map<String, dynamic>? open;
  for (var i = 0; i < ordered.length; i++) {
    final type = ordered[i]['record_type']?.toString();
    if (type == 'check_in') {
      open = _isLegacyBatchNightEntry(ordered, i) ? null : ordered[i];
    } else if (type == 'check_out') {
      open = null;
    }
  }
  return open;
}

/// Primeiro ponto de [day] (os pontos de um dia) quando o dia comeca sem
/// entrada e a vespera [previousDay] nao tem turno aberto, ate [maxShiftSpan]
/// antes dele, que o explique; ou null. As telas que guardam a vespera em
/// cache leem de novo quando aparece um ponto desses: o lote do gestor grava
/// a madrugada da noite (pausas e saida) na data real depois de a vespera ja
/// ter sido lida, e sem a entrada dela esses pontos viravam o comeco do dia.
Map<String, dynamic>? dayStartWithoutShift(
    Iterable<dynamic> previousDay, Iterable<dynamic> day) {
  final ordered = _chronological(day);
  if (ordered.isEmpty || ordered.first['record_type'] == 'check_in') {
    return null;
  }
  final first = ordered.first;
  final firstAt = DateTime.tryParse(first['timestamp'].toString());
  final openAt = DateTime.tryParse(
      openShiftCheckIn(previousDay)?['timestamp']?.toString() ?? '');
  if (firstAt != null &&
      openAt != null &&
      firstAt.difference(openAt) <= maxShiftSpan) {
    return null;
  }
  return first;
}

/// Agrupa os pontos pelo dia de trabalho (yyyy-MM-dd): a data da entrada do
/// turno a que cada ponto pertence, nao a data do proprio ponto. Agrupar pela
/// data de cada ponto deixava a entrada 19:30 sozinha num dia e a saida 07:00
/// no outro, e nenhum dos dois somava horas.
///
/// Pontos sem turno aberto, ou a mais de [maxShiftSpan] da entrada sem estar
/// ligados a ela ([belongsToShift]), ficam no proprio dia, assim como o turno
/// da noite do lote antigo do gestor. O ponto ligado ao turno e dele, qualquer
/// que seja a distancia (jornada sem limite, 09/11/2026). Dentro
/// de cada dia a ordem e cronologica. O lote novo (data real) segue a regra
/// comum, como o app.
///
/// Saida repetida, sem entrada depois do turno que fechou, corrige a saida
/// dele (vale a ultima) ate [maxShiftSpan] da entrada, mesmo que caia no dia
/// seguinte: e a saida real que o gestor lanca para a noite fechada no
/// horario errado. As pausas antes dela, depois do turno fechado, vao junto
/// para o dia dele: a pausa que o lote lanca com a saida (Saida batida no
/// lugar da Pausa as 03:00, lote com a pausa 03:30-04:30 e a saida 07:00)
/// ficava solta no dia seguinte, e a noite pagava a pausa (ou so a 1h
/// padrao da pausa sem fim) como trabalhada. Pausa sem saida repetida depois
/// fica no proprio dia.
///
/// Duas saidas nao encerram o turno aberto aqui (openShiftCheckIn continua
/// tratando como fechado):
///   - a do turno da noite do lote antigo, reservada para ele
///     (manualNightMorning):
///     a saida real do turno do app da vespera, batida segundos depois, ia
///     para o dia seguinte, onde nao tem entrada e nao conta;
///   - a do "Esqueci" (menos de 1 min depois da entrada, a mesma regra do
///     calculo do dia): a saida real que o gestor lanca depois, ja na manha
///     seguinte, precisa cair no dia da entrada para valer.
///
/// A refeicao da noite batida como saida e entrada depois da meia-noite
/// (19:30-23:30 e 00:30-07:00) e um dia de trabalho so: a entrada da volta
/// fica no dia do turno que acabou de fechar (_resumesAfterMeal). Separada,
/// a metade da madrugada ia para a linha do dia seguinte (ou para o periodo
/// seguinte) e o intervalo nao cancelava o jantar automatico: 1h a menos.
Map<String, List<Map<String, dynamic>>> groupRecordsByWorkDay(
    Iterable<dynamic> records) {
  final ordered = _chronological(records);
  final nightMorning = allManualNightMorning(ordered);
  final times = [
    for (final record in ordered)
      DateTime.tryParse(record['timestamp'].toString())
  ];
  // Proxima entrada ou saida depois de cada ponto (indice em ordered). A
  // saida reservada para a noite do lote antigo e dela, nao do turno que
  // fechou: contada aqui, a pausa do lote antes dela ficava no proprio dia
  // e nao ia com a saida que corrige a noite (a pausa era paga).
  final nextMark = List<int?>.filled(ordered.length, null);
  int? next;
  for (var i = ordered.length - 1; i >= 0; i--) {
    nextMark[i] = next;
    final type = ordered[i]['record_type'];
    if ((type == 'check_in' || type == 'check_out') &&
        !nightMorning.contains(i)) {
      next = i;
    }
  }
  final grouped = <String, List<Map<String, dynamic>>>{};
  String? openDay;
  DateTime? openAt;
  String? openId;
  // Turno que acabou de fechar (ate a proxima entrada): dia de trabalho,
  // entrada e saida.
  String? closedDay;
  DateTime? closedEntryAt;
  DateTime? closedExitAt;
  // A saida em [index], sem turno aberto, e a saida repetida do turno que
  // fechou (vale a ultima)? Ate maxShiftSpan da entrada dele, mesmo no dia
  // seguinte.
  bool repeatsClosedExit(int index) {
    final at = times[index];
    return openDay == null &&
        closedDay != null &&
        ordered[index]['record_type'] == 'check_out' &&
        !nightMorning.contains(index) &&
        (_dayOf(ordered[index]) == closedDay ||
            (at != null &&
                closedEntryAt != null &&
                at.difference(closedEntryAt) <= maxShiftSpan));
  }

  for (var i = 0; i < ordered.length; i++) {
    final record = ordered[i];
    final type = record['record_type']?.toString();
    var day = _dayOf(record);
    final at = times[i];
    if (type == 'check_in') {
      final closed = _isLegacyBatchNightEntry(ordered, i);
      if (!closed &&
          closedDay != null &&
          _resumesAfterMeal(day, at, closedDay, closedEntryAt, closedExitAt)) {
        day = closedDay;
      }
      openDay = closed ? null : day;
      openAt = closed ? null : at;
      openId = closed ? null : record['id']?.toString();
      closedDay = null;
      closedEntryAt = null;
      closedExitAt = null;
    } else if (openDay != null &&
        openAt != null &&
        day != openDay &&
        !nightMorning.contains(i)) {
      if (at != null &&
          (at.difference(openAt) <= maxShiftSpan ||
              belongsToShift(record, openId))) {
        day = openDay;
      }
    } else if (_pauseTypes.contains(type) &&
        !nightMorning.contains(i) &&
        nextMark[i] != null &&
        repeatsClosedExit(nextMark[i]!)) {
      // Pausa entre o turno fechado e a saida repetida que o corrige: vai
      // com ela para o dia do turno (_pairShifts a soma ao turno quando a
      // saida repetida chega).
      day = closedDay!;
    }
    if (type == 'check_out') {
      final forgotten = openAt != null &&
          at != null &&
          at.difference(openAt) < const Duration(minutes: 1);
      if (!forgotten && !nightMorning.contains(i)) {
        if (repeatsClosedExit(i)) {
          // Saida repetida do turno que ja fechou: vale a ultima, mesmo no
          // dia seguinte (ate maxShiftSpan da entrada). A noite fechada por
          // engano as 03:00 e corrigida pelo lote com a saida 07:00 na data
          // real ficava com a saida solta no dia seguinte e pagava so 6,5h.
          day = closedDay!;
          closedExitAt = at;
        } else {
          final closesOpen = openDay != null && day == openDay;
          closedDay = closesOpen ? openDay : null;
          closedEntryAt = closesOpen ? openAt : null;
          closedExitAt = closesOpen ? at : null;
        }
        openDay = null;
        openAt = null;
        openId = null;
      }
    }
    grouped.putIfAbsent(day, () => []).add(record);
  }
  return grouped;
}

/// A entrada em [at], na data [day], e a volta da refeicao do turno do dia
/// de trabalho [closedDay] que fechou em [exitAt]? E quando ela cai no dia
/// seguinte ao dele, ate [maxMealGap] depois da saida, ainda na madrugada
/// (antes das 05:00, fim do noturno) e a ate [maxShiftSpan] da entrada
/// [entryAt]. A entrada 08:00 depois da noite 19:30-07:00 e outro turno, do
/// proprio dia.
bool _resumesAfterMeal(String day, DateTime? at, String closedDay,
    DateTime? entryAt, DateTime? exitAt) {
  if (at == null || entryAt == null || exitAt == null) return false;
  if (day == closedDay || at.hour >= 5) return false;
  final gap = at.difference(exitAt);
  return !gap.isNegative &&
      gap <= maxMealGap &&
      at.difference(entryAt) <= maxShiftSpan;
}
