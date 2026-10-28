import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';
import 'dart:math' as math;
import '../services/api_service.dart';
import '../utils/daily_entries.dart';
import '../utils/shift_records.dart';
import '../utils/timesheet.dart';
import 'monthly_dashboard_screen.dart';
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
  DateTime _timelineDate = DateTime.now();
  // A linha do tempo acompanha o dia de hoje ate o usuario escolher outra
  // data. Com o painel aberto na virada do dia, ela ficava presa em ontem.
  bool _timelineFollowsToday = true;
  List<int> _hourlyActivity = List.filled(24, 0);
  // Pontos da vespera do dia da linha do tempo, para o turno que atravessa
  // a meia-noite. Dia passado quase nao muda e o painel atualiza a cada 30 s:
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
      if (_timelineFollowsToday) _timelineDate = now;
      final userId = _selectedUser!['id'];
      final day =
          DateTime(_timelineDate.year, _timelineDate.month, _timelineDate.day);

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
        _hourlyActivity =
            _hourlyActivityFor(day, now, previousDay, rawRecords);
      });
    } catch (e) {
      debugPrint('Erro dashboard: $e');
    }
  }

  /// Modo diaria (users.daily_mode): os dias vem das diarias, cada uma com o
  /// dia padrao da folha (exportTimesheet ja devolve assim).
  bool get _isDailyUser => _selectedUser?['daily_mode'] == true;

  /// Linha do tempo do dia [day] no modo diaria: os pontos do dia padrao,
  /// se houve diaria nele. Dia fora da semana carregada pede as diarias dele.
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

  /// Ocupacao de cada hora do dia [day] na linha do tempo: 0 nada,
  /// 1 trabalho, 2 pausa, 3 hora atual. Entra o turno que vinha aberto da
  /// vespera ([previousDay]) e, num dia passado, o que ficou aberto na
  /// meia-noite (vai ate 24:00). So com os pontos do proprio dia, o turno
  /// 19:30-07:00 nao aparecia em nenhum dos dois dias. Cada hora fica com o
  /// que ocupou mais tempo dela.
  List<int> _hourlyActivityFor(DateTime day, DateTime now,
      List<dynamic> previousDay, List<dynamic> dayRecords) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    final workSeconds = List<int>.filled(24, 0);
    final pauseSeconds = List<int>.filled(24, 0);

    void paint(DateTime from, DateTime to, bool pause) {
      var cursor = from.isBefore(dayStart) ? dayStart : from;
      final end = to.isAfter(dayEnd) ? dayEnd : to;
      while (cursor.isBefore(end)) {
        final nextHour =
            DateTime(cursor.year, cursor.month, cursor.day, cursor.hour + 1);
        final sliceEnd = nextHour.isBefore(end) ? nextHour : end;
        (pause ? pauseSeconds : workSeconds)[cursor.hour] +=
            sliceEnd.difference(cursor).inSeconds;
        cursor = sliceEnd;
      }
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
    // Turno ainda aberto: hoje vai ate agora; num dia passado, ate 24:00.
    if (shiftStart != null) closeSegment(now.isBefore(dayEnd) ? now : dayEnd);

    final activity = List<int>.generate(24, (hour) {
      if (workSeconds[hour] == 0 && pauseSeconds[hour] == 0) return 0;
      return pauseSeconds[hour] > workSeconds[hour] ? 2 : 1;
    });
    if (!now.isBefore(dayStart) && now.isBefore(dayEnd)) {
      activity[now.hour] = 3;
    }
    return activity;
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
              onRefresh: () => _fetchDashboardData(refreshPreviousDay: true),
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
                    const SizedBox(height: 24),
                    _buildSummaryCards(),
                    if (_isDailyUser) ...[
                      const SizedBox(height: 12),
                      _buildDailyModeNote(),
                    ],
                    const SizedBox(height: 24),
                    _buildTimelineChart(),
                    const SizedBox(height: 24),
                    _buildWeeklyTimelineChart(),
                    const SizedBox(height: 24),
                    _buildWeeklyHours(),
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
        const SizedBox(width: 14),
        _buildMonthlyEntry(),
      ],
    );
  }

  /// Acesso a visao mensal: alvo compacto no cabecalho, com anel fino e
  /// halo tenue em vez de um bloco solido.
  Widget _buildMonthlyEntry() {
    if (_selectedUser == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Tooltip(
      message: 'Meu Mês',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MonthlyDashboardScreen(
                user: Map<String, dynamic>.from(_selectedUser!),
              ),
            ),
          ),
          child: Ink(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: wineColor.withValues(alpha: 0.45)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  wineColor.withValues(alpha: isDark ? 0.30 : 0.10),
                  wineColor.withValues(alpha: 0.02),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: wineColor.withValues(alpha: isDark ? 0.35 : 0.18),
                  blurRadius: 10,
                  spreadRadius: -2,
                ),
              ],
            ),
            // Variante base do icone: as variantes rounded/sharp nem sempre
            // tem glifo na MaterialIcons empacotada e saem em branco.
            child: const Center(
              child: Icon(Icons.auto_graph, color: wineColor, size: 22),
            ),
          ),
        ),
      ),
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

  Widget _buildSummaryCards() {
    final record = _dailyRecords.isNotEmpty ? _dailyRecords.first : null;
    final double hours = record?['total_hours'] ?? 0.0;
    final int h = hours.toInt();
    final int m = ((hours - h) * 60).round();

    bool isEstagiario = (_selectedUser?['role'] ?? '')
            .toString()
            .toLowerCase()
            .contains('estag') ||
        (_selectedUser?['role'] ?? '')
            .toString()
            .toLowerCase()
            .contains('intern');

    final double weeklyGoal = isEstagiario ? 30.0 : 44.0;
    final double balance = _weeklyTotalHours - weeklyGoal;
    final String balanceStr = balance >= 0
        ? '+${balance.toStringAsFixed(1)}h'
        : '${balance.toStringAsFixed(1)}h';

    return Row(
      children: [
        _buildCard('HORAS HOJE', '${h}h ${m}m', 'acumulado', isPrimary: true),
        const SizedBox(width: 10),
        _buildCard('ENTRADA', record?['check_in'] ?? '--:--', 'no prazo'),
        const SizedBox(width: 10),
        _buildCard('SALDO SEMANA', balanceStr,
            balance >= 0 ? 'acima da meta' : 'abaixo da meta'),
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

  Widget _buildTimelineChart() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('LINHA DO TEMPO — DIA',
                  style: TextStyle(
                      color: Colors.grey,
                      fontSize: 10,
                      fontWeight: FontWeight.bold)),
              TextButton.icon(
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _timelineDate,
                    firstDate: DateTime(2023),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() {
                      _timelineDate = picked;
                      _timelineFollowsToday =
                          DateUtils.isSameDay(picked, DateTime.now());
                    });
                    _fetchDashboardData();
                  }
                },
                icon: const Icon(Icons.calendar_today,
                    size: 12, color: wineColor),
                label: Text(
                  DateFormat('dd/MM/yy').format(_timelineDate),
                  style: const TextStyle(
                      color: wineColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold),
                ),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero, minimumSize: Size.zero),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 80,
            child: BarChart(
              BarChartData(
                maxY: 10,
                barGroups: List.generate(24, (i) {
                  int type = _hourlyActivity[i];
                  return BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: type > 0 ? 8 : 0,
                        color: type == 2
                            ? Colors.orange
                            : (type == 3
                                ? Colors.blue
                                : Colors.blue.withValues(alpha: 0.4)),
                        width: 6,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ],
                  );
                }),
                gridData: const FlGridData(show: false),
                titlesData: FlTitlesData(
                  leftTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 18,
                      getTitlesWidget: (val, meta) {
                        if (val % 2 == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 4.0),
                            child: Text('${val.toInt()}h',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 8)),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                barTouchData: BarTouchData(enabled: false),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildLegend(Colors.blue.withValues(alpha: 0.4), 'Trabalhado'),
              const SizedBox(width: 12),
              _buildLegend(Colors.orange, 'Pausa'),
              const SizedBox(width: 12),
              _buildLegend(Colors.blue, 'Momento atual'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(Color color, String label) {
    return Row(
      children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 9)),
      ],
    );
  }

  /// Horas de cada dia da semana (seg a dom) pelo total do dia, que ja
  /// desconta as pausas e soma no dia da entrada o turno que passou da
  /// meia-noite. A conta antiga (hora da saida menos hora da entrada da
  /// primeira sessao) dava 1h para 19:30-07:00, nada para 22:00-06:00 e so a
  /// manha num dia com almoco.
  List<double> _weekdayHours() {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    return List.generate(7, (index) {
      final key = DateFormat('yyyy-MM-dd')
          .format(DateTime(monday.year, monday.month, monday.day + index));
      for (final record in _weeklyRecords) {
        if (record is Map && record['date'] == key) {
          final hours = record['total_hours'];
          return hours is num ? hours.toDouble() : 0.0;
        }
      }
      return 0.0;
    });
  }

  String _barLabel(double hours) {
    final minutes = (hours * 60).round();
    if (minutes <= 0) return '';
    final m = minutes % 60;
    return '${minutes ~/ 60}h${m > 0 ? m.toString().padLeft(2, '0') : ''}';
  }

  Widget _buildWeeklyTimelineChart() {
    final weekHours = _weekdayHours();
    // Turno de 12h ou mais (noite) nao cabia no eixo fixo de 12h.
    final maxY =
        math.max(12.0, (weekHours.reduce(math.max) + 1).ceilToDouble());
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LINHA DO TEMPO — SEMANA',
              style: TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          SizedBox(
            height: 100,
            child: BarChart(
              BarChartData(
                maxY: maxY,
                barGroups: List.generate(7, (index) {
                  final hours = weekHours[index];
                  return BarChartGroupData(
                    x: index,
                    barRods: [
                      BarChartRodData(
                        toY: hours > 0 ? hours : 0.1,
                        color: wineColor.withValues(alpha: 0.8),
                        width: 10,
                        borderRadius: BorderRadius.circular(2),
                        backDrawRodData: BackgroundBarChartRodData(
                          show: true,
                          toY: 10,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: 0.03)
                              : Colors.black.withValues(alpha: 0.03),
                        ),
                      ),
                    ],
                    showingTooltipIndicators: [0],
                  );
                }),
                gridData: const FlGridData(show: false),
                titlesData: FlTitlesData(
                  leftTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 18,
                      getTitlesWidget: (val, meta) {
                        const days = [
                          'Seg',
                          'Ter',
                          'Qua',
                          'Qui',
                          'Sex',
                          'Sáb',
                          'Dom'
                        ];
                        if (val >= 0 && val < 7) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 6.0),
                            child: Text(days[val.toInt()],
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 8)),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                barTouchData: BarTouchData(
                  enabled: false,
                  touchTooltipData: BarTouchTooltipData(
                    tooltipBgColor: Colors.transparent,
                    tooltipPadding: EdgeInsets.zero,
                    tooltipMargin: 4,
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      return BarTooltipItem(
                        _barLabel(weekHours[group.x]),
                        TextStyle(
                            color:
                                Theme.of(context).textTheme.bodyMedium?.color,
                            fontWeight: FontWeight.bold,
                            fontSize: 9),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeeklyHours() {
    bool isEstagiario = (_selectedUser?['role'] ?? '')
            .toString()
            .toLowerCase()
            .contains('estag') ||
        (_selectedUser?['role'] ?? '')
            .toString()
            .toLowerCase()
            .contains('intern');

    final double weeklyGoal = isEstagiario ? 30.0 : 44.0;
    final double progress = (_weeklyTotalHours / weeklyGoal).clamp(0.0, 1.0);
    final int h = _weeklyTotalHours.toInt();
    final int m = ((_weeklyTotalHours - h) * 60).round();
    final textColor = Theme.of(context).textTheme.bodyLarge?.color;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('HORAS NA SEMANA (${isEstagiario ? "META 30H" : "META 44H"})',
              style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 6,
                  backgroundColor:
                      Theme.of(context).brightness == Brightness.dark
                          ? Colors.white.withValues(alpha: 0.03)
                          : Colors.black.withValues(alpha: 0.03),
                  color: wineColor,
                ),
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${h}h ${m}m',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: textColor)),
                  Row(
                    children: [
                      Text('meta: ${weeklyGoal.toInt()}h',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 10)),
                      const SizedBox(width: 8),
                      if (progress < 0.8)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(20)),
                          child: const Text('ATENÇÃO',
                              style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
