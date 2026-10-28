import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import '../services/api_service.dart';
import '../utils/daily_entries.dart';
import '../utils/shift_records.dart';
import '../utils/timesheet.dart';
import '../utils/work_schedule_rules.dart' show isInternProfile;
import 'month_overview.dart';
import '../utils/screen_watch.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _apiService = ApiService();
  bool _isLoading = true;
  Map<String, dynamic>? _selectedUser;
  List<dynamic> _users = [];
  List<dynamic> _dailyRecords = [];
  List<dynamic> _weeklyRecords = [];
  double _weeklyTotalHours = 0;
  // Trabalhado hoje ate agora, com o turno aberto (a folha so conta o que
  // ja fechou: com a entrada das 08:00 aberta, "hoje" mostrava 0h 0m).
  int _todaySeconds = 0;
  // Recarrega o mes (puxar a tela para baixo).
  int _monthReload = 0;
  // Pontos da vespera de hoje, para o turno que atravessa a meia-noite. Dia passado quase nao muda e o painel atualiza a cada 30 s:
  // le uma vez por usuario e dia (puxar a tela para baixo le de novo).
  String? _previousDayKey;
  List<dynamic> _previousDayRecords = const [];
  // Ponto do dia que comeca sem entrada e que a vespera lida nao explica
  // (dayStartWithoutShift): a vespera mudou depois de lida (a noite lancada
  // no lote do gestor grava a madrugada no dia seguinte). Pede uma leitura
  // nova, uma vez por ponto.
  String? _previousDayCheckedStart;
  Timer? _timer;
  DateTime _now = DateTime.now();

  static const Color wineColor = Color(0xFF8B0000);

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
    _timer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted && isScreenWatched(context)) {
        setState(() => _now = DateTime.now());
        _fetchDashboardData();
      }
    });
  }

  String _firstName(dynamic value) {
    final fullName = (value ?? '').toString().trim();
    if (fullName.isEmpty) return '';
    return fullName.split(RegExp(r'\s+')).first;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() => _isLoading = true);
    try {
      final currentUser = await _apiService.getCurrentUser();
      if (currentUser['role'] == 'admin' || currentUser['role'] == 'manager') {
        _users = await _apiService.getUsers();
      } else {
        _users = [currentUser];
      }
      _selectedUser = _users.first;
      await _fetchDashboardData();
    } catch (e) {
      debugPrint('Erro init: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Ultimo instante do dia. Com microssegundos: o backend grava
  /// 23:59:59.123456, que na comparacao de texto fica depois de "23:59:59".
  static DateTime _endOfDay(DateTime day) =>
      DateTime(day.year, day.month, day.day, 23, 59, 59, 999, 999);

  Future<void> _fetchDashboardData({bool refreshPreviousDay = false}) async {
    if (_selectedUser == null) return;
    try {
      final now = DateTime.now();
      final userId = _selectedUser!['id'];
      final day = DateTime(now.year, now.month, now.day);

      // A semana ja traz o dia de hoje, agrupado como na folha (pelo dia da
      // entrada): uma exportacao so a cada 30 s em vez de duas.
      final startWeek =
          DateTime(now.year, now.month, now.day - (now.weekday - 1));
      final weekData = await _apiService.exportTimesheet(
          startDate: startWeek.toIso8601String(),
          endDate: _endOfDay(now).toIso8601String(),
          userId: userId);
      final weekRecords = List<dynamic>.from(weekData['daily_records'] as List);
      final todayKey = DateFormat('yyyy-MM-dd').format(now);

      final List<dynamic> rawRecords;
      final List<dynamic> previousDay;
      if (_isDailyUser) {
        rawRecords = await _dailyTimelineRecords(day, startWeek, weekRecords);
        previousDay = const [];
      } else {
        rawRecords = await _apiService.getTimeRecords(
            startDate: day.toIso8601String(),
            endDate: _endOfDay(day).toIso8601String(),
            userId: userId);
        previousDay = await _loadPreviousDayRecords(
            userId, day, rawRecords, refreshPreviousDay);
      }

      // Troca de funcionario no meio da leitura: descarta o resultado velho.
      if (!mounted || _selectedUser?['id'] != userId) return;
      setState(() {
        _dailyRecords =
            weekRecords.where((r) => r['date'] == todayKey).toList();
        _weeklyRecords = weekRecords;
        _weeklyTotalHours =
            double.tryParse(weekData['summary']['total_hours']) ?? 0.0;
        _todaySeconds = _workedSecondsFor(day, now, previousDay, rawRecords);
      });
    } catch (e) {
      debugPrint('Erro dashboard: $e');
    }
  }

  /// Modo diaria (users.daily_mode): os dias vem das diarias, cada uma com o
  /// dia padrao da folha (exportTimesheet ja devolve assim).
  bool get _isDailyUser => _selectedUser?['daily_mode'] == true;

  /// Pontos do dia [day] no modo diaria: os do dia padrao, se houve diaria
  /// nele. Dia fora da semana carregada pede as diarias dele.
  Future<List<dynamic>> _dailyTimelineRecords(
      DateTime day, DateTime startWeek, List<dynamic> weekRecords) async {
    final key = DateFormat('yyyy-MM-dd').format(day);
    bool hasEntry(Iterable<dynamic> days) =>
        days.any((record) => record is Map && record['date'] == key);
    var worked = hasEntry(weekRecords);
    if (!worked && day.isBefore(startWeek)) {
      final data = await _apiService.exportTimesheet(
          startDate: day.toIso8601String(),
          endDate: _endOfDay(day).toIso8601String(),
          userId: _selectedUser!['id']);
      worked = hasEntry(data['daily_records'] as List);
    }
    if (!worked) return const [];
    return dailyStandardRecords(_selectedUser?['name']?.toString() ?? '', key,
        _selectedUser?['daily_hours']);
  }

  Future<List<dynamic>> _loadPreviousDayRecords(dynamic userId, DateTime day,
      List<dynamic> dayRecords, bool force) async {
    final previous = DateTime(day.year, day.month, day.day - 1);
    final key = '$userId|${DateFormat('yyyy-MM-dd').format(previous)}';
    String? startWithoutShift(List<dynamic> previousDay) {
      final start = dayStartWithoutShift(previousDay, dayRecords);
      return start == null ? null : '${start['id'] ?? start['timestamp']}';
    }

    if (!force && key == _previousDayKey) {
      final start = startWithoutShift(_previousDayRecords);
      if (start == null || start == _previousDayCheckedStart) {
        return _previousDayRecords;
      }
    }
    final records = await _apiService.getTimeRecords(
        startDate: previous.toIso8601String(),
        endDate: _endOfDay(previous).toIso8601String(),
        userId: userId);
    _previousDayKey = key;
    _previousDayRecords = records;
    // O que nem a vespera nova explica nao pede outra leitura.
    _previousDayCheckedStart = startWithoutShift(records);
    return records;
  }

  /// Segundos trabalhados no dia [day] ate [now]. Entra o turno que vinha
  /// aberto da vespera ([previousDay]) e o turno ainda aberto (ate agora).
  /// So com os pontos do proprio dia, o turno 19:30-07:00 nao aparecia em
  /// nenhum dos dois dias.
  int _workedSecondsFor(DateTime day, DateTime now,
      List<dynamic> previousDay, List<dynamic> dayRecords) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    var workSeconds = 0;

    void paint(DateTime from, DateTime to, bool pause) {
      if (pause) return;
      final start = from.isBefore(dayStart) ? dayStart : from;
      final end = to.isAfter(dayEnd) ? dayEnd : to;
      if (end.isAfter(start)) workSeconds += end.difference(start).inSeconds;
    }

    DateTime? shiftStart;
    DateTime? segmentStart;
    var paused = false;
    var resumedByAutomaticEnd = false;

    // Desenha o trecho aberto ate [at]. Passadas [maxShiftSpan] da entrada
    // e saida esquecida, nao turno: o trecho para ali.
    void closeSegment(DateTime at, {bool? pause}) {
      final start = shiftStart;
      final from = segmentStart;
      if (start == null || from == null) return;
      final limit = start.add(maxShiftSpan);
      paint(from, at.isAfter(limit) ? limit : at, pause ?? paused);
    }

    for (final (at, record) in _timelineMarks([...previousDay, ...dayRecords])) {
      switch (record['record_type']) {
        case 'check_in':
          closeSegment(at);
          shiftStart = at;
          segmentStart = at;
          paused = false;
          resumedByAutomaticEnd = false;
        case 'break_start':
        case 'entry_3':
          if (shiftStart == null || paused) break;
          closeSegment(at);
          segmentStart = at;
          paused = true;
          resumedByAutomaticEnd = false;
        case 'break_end':
        case 'exit_3':
          if (shiftStart == null) break;
          final automatic = isAutomaticBreakEnd(record);
          if (paused) {
            closeSegment(at);
          } else if (resumedByAutomaticEnd && !automatic) {
            // Fim real depois do automatico na mesma pausa (ponto offline
            // que sincronizou tarde): a pausa vai ate o real, como na folha.
            closeSegment(at, pause: true);
          } else {
            break;
          }
          segmentStart = at;
          paused = false;
          resumedByAutomaticEnd = automatic;
        case 'check_out':
          closeSegment(at);
          shiftStart = null;
          segmentStart = null;
          paused = false;
          resumedByAutomaticEnd = false;
      }
    }
    // Turno ainda aberto: vai ate agora.
    if (shiftStart != null) closeSegment(now.isBefore(dayEnd) ? now : dayEnd);

    return workSeconds;
  }

  /// Pontos em ordem, cada um na hora em que de fato aconteceu. O lote
  /// antigo do gestor gravava o turno da noite inteiro na data escolhida
  /// (saida 07:00 antes da entrada 19:30): a saida e as pausas da madrugada
  /// desse turno (allManualNightMorning, so pontos de isLegacyBatchRecord)
  /// sao da manha seguinte, como no calculo da folha. O lote novo ja grava a
  /// data real e entra como esta.
  List<(DateTime, Map<String, dynamic>)> _timelineMarks(
      Iterable<dynamic> records) {
    final ordered = sortRecords([
      for (final raw in records) Map<String, dynamic>.from(raw as Map),
    ]
        .where((record) =>
            DateTime.tryParse(record['timestamp']?.toString() ?? '') != null)
        .toList());
    final nextMorning = allManualNightMorning(ordered);
    final marks = <(DateTime, Map<String, dynamic>)>[];
    for (var i = 0; i < ordered.length; i++) {
      var at = DateTime.parse(ordered[i]['timestamp'].toString()).toLocal();
      if (nextMorning.contains(i)) {
        at = DateTime(at.year, at.month, at.day + 1, at.hour, at.minute,
            at.second, at.millisecond, at.microsecond);
      }
      marks.add((at, ordered[i]));
    }
    // Na ordem da folha (chronologicalOrder), com a manha da noite do lote
    // antigo no dia seguinte: no mesmo horario a ordem vem do tipo (a saida
    // antes da entrada do turno seguinte, o fim da pausa antes da saida), e o
    // ponto do lote fica no lugar dele no minuto da batida do app. Pela hora
    // crua, a Entrada 07:00 do lote vinha antes da Saida 07:00:14 da noite.
    final order = chronologicalOrder([
      for (var i = 0; i < marks.length; i++)
        nextMorning.contains(i)
            ? {...marks[i].$2, 'timestamp': marks[i].$1.toIso8601String()}
            : marks[i].$2,
    ]);
    return [for (final i in order) marks[i]];
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: wineColor))
          : RefreshIndicator(
              onRefresh: () {
                setState(() => _monthReload++);
                return _fetchDashboardData(refreshPreviousDay: true);
              },
              color: wineColor,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(16, topInset + 32, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 20),
                    _buildUserSwitcher(),
                    const SizedBox(height: 16),
                    _buildSummaryCards(),
                    if (_isDailyUser) ...[
                      const SizedBox(height: 12),
                      _buildDailyModeNote(),
                    ],
                    const SizedBox(height: 20),
                    // O mes (antes a tela "Meu Mes"): calendario com as horas
                    // de cada dia; meta e saldo so para o estagiario.
                    if (_selectedUser != null)
                      MonthOverview(
                        key: ValueKey('${_selectedUser!['id']}|$_monthReload'),
                        user: Map<String, dynamic>.from(_selectedUser!),
                        todayRecord: _dailyRecords.isEmpty
                            ? null
                            : Map<String, dynamic>.from(
                                _dailyRecords.first as Map),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildHeader() {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CONTROLE DE JORNADA',
                  style: TextStyle(
                      color: Colors.grey, fontSize: 10, letterSpacing: 1.2)),
              Text(
                _firstName(_selectedUser?['name']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: textColor),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(DateFormat('EEE, dd MMM yyyy', 'pt_BR').format(_now),
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            Text(DateFormat('HH:mm:ss').format(_now),
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Roboto',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: textColor)),
          ],
        ),
      ],
    );
  }

  Widget _buildUserSwitcher() {
    if (_users.length <= 1) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DropdownButtonFormField<dynamic>(
        // initialValue so vale na criacao: a chave recria o campo quando
        // a selecao muda pelo codigo (recarga volta ao primeiro da lista).
        key: ValueKey(_selectedUser?['id']),
        initialValue: _selectedUser?['id'],
        dropdownColor: Theme.of(context).cardColor,
        decoration: InputDecoration(
          labelText: 'Selecionar Funcionário',
          labelStyle: const TextStyle(color: Colors.grey),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white24),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: wineColor),
          ),
          filled: true,
          fillColor: Theme.of(context).cardColor,
        ),
        style: TextStyle(
            color: Theme.of(context).textTheme.bodyMedium?.color, fontSize: 14),
        items: _users.map((user) {
          return DropdownMenuItem(
            value: user['id'],
            child: Text(user['name']),
          );
        }).toList(),
        onChanged: (val) {
          if (val != null) {
            final user = _users.firstWhere((u) => u['id'] == val);
            setState(() => _selectedUser = user);
            _fetchDashboardData();
          }
        },
      ),
    );
  }

  String _hm(double hours) {
    final total = (hours * 60).round();
    return '${total ~/ 60}h ${(total % 60).toString().padLeft(2, '0')}m';
  }

  /// Hoje e a semana, ate agora. Meta so para o estagiario (carga fixa por
  /// dia util); os demais fazem o proprio horario e veem so o que fizeram.
  Widget _buildSummaryCards() {
    final record = _dailyRecords.isNotEmpty ? _dailyRecords.first : null;
    final todayHours = _todaySeconds / 3600;
    // A semana da folha so tem o que ja fechou: troca o hoje dela pelo de
    // agora.
    final closedToday = double.tryParse('${record?['total_hours'] ?? 0}') ?? 0;
    final weekHours = _weeklyTotalHours - closedToday + todayHours;
    final checkIn = record?['check_in']?.toString();

    final bool isEstagiario = isInternProfile(_selectedUser);
    final dailyTarget =
        double.tryParse('${_selectedUser?['daily_hours'] ?? ''}') ?? 6.0;

    return Row(
      children: [
        _buildCard('HOJE', _hm(todayHours),
            checkIn == null ? 'sem ponto hoje' : 'entrada $checkIn',
            isPrimary: true),
        const SizedBox(width: 10),
        _buildCard(
            'SEMANA',
            _hm(weekHours),
            isEstagiario && !_isDailyUser
                ? 'meta ${(dailyTarget * 5).toStringAsFixed(0)}h'
                : 'trabalhadas'),
      ],
    );
  }

  /// Aviso do modo diaria: quantas diarias na semana e de onde vem o horario.
  Widget _buildDailyModeNote() {
    final count = _weeklyRecords.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: wineColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: wineColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_available, color: wineColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Modo diária: $count diária(s) nesta semana. Cada diária '
              'aparece com o horário padrão do dia, o mesmo da folha de ponto.',
              style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(String title, String value, String sub,
      {bool isPrimary = false}) {
    final cardColor =
        isPrimary ? wineColor.withValues(alpha: 0.1) : Theme.of(context).cardColor;
    final textColor = Theme.of(context).textTheme.bodyLarge?.color;

    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isPrimary ? wineColor : Colors.white.withValues(alpha: 0.05),
              width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 9,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: textColor)),
            const SizedBox(height: 2),
            Text(sub,
                style: TextStyle(
                    color: isPrimary ? wineColor : Colors.grey, fontSize: 9)),
          ],
        ),
      ),
    );
  }
}
