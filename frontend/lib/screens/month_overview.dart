import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/timesheet.dart' show isHoliday;
import '../utils/work_schedule_rules.dart' show isInternProfile;

/// O mes na Dash (antes a tela "Meu Mes"): periodo da folha (29 a 28), o
/// calendario com as horas de cada dia e, tocando no dia, os horarios dele.
/// Meta e saldo so para o estagiario, que tem carga fixa por dia util; os
/// demais fazem o proprio horario e veem so o que trabalharam e as extras.
class MonthOverview extends StatefulWidget {
  const MonthOverview({super.key, required this.user, this.todayRecord});

  final Map<String, dynamic> user;

  /// Dia de hoje ja calculado pela Dash (atualiza a cada 30 s). Substitui o
  /// de hoje lido com o mes, para o calendario nao ficar parado na abertura.
  final Map<String, dynamic>? todayRecord;

  /// So para teste da tela sem Firebase: substitui a busca da folha. No app
  /// fica sempre nulo.
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(DateTime start, DateTime end)?
      debugLoader;

  /// So para teste: o "hoje" da tela.
  @visibleForTesting
  static DateTime Function()? debugNow;

  @override
  State<MonthOverview> createState() => _MonthOverviewState();
}

class _MonthOverviewState extends State<MonthOverview> {
  static const Color wineColor = Color(0xFF8B0000);
  static const Color _muted = Color(0xFF898781);
  static const Color _green = Color(0xFF0CA30C);
  static const Color _orange = Color(0xFFE08A00);
  static const Color _red = Color(0xFFD03B3B);
  static const Color _purple = Color(0xFF8E6BBF);
  static const Color _blue = Color(0xFF3987E5);

  // Lazy: so cria (e toca no Firebase) quando busca a folha.
  late final _apiService = ApiService();
  bool _isLoading = true;
  String? _error;

  late DateTime _month;
  DateTime? _selected;
  List<Map<String, dynamic>> _days = [];
  Map<String, dynamic> _summary = {};

  DateTime get _now => MonthOverview.debugNow?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final now = _now;
    // O periodo fecha no dia 28. A partir do dia 29 ja estamos no periodo
    // do mes seguinte.
    _month = now.day >= 29
        ? DateTime(now.year, now.month + 1)
        : DateTime(now.year, now.month);
    _selected = _today;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    final month = _month;
    try {
      final start = _periodStart;
      // Fim do dia com microssegundos: o backend grava 23:59:59.123456, que
      // na comparacao de texto fica depois de "23:59:59".
      final end = DateTime(_periodEnd.year, _periodEnd.month, _periodEnd.day,
          23, 59, 59, 999, 999);
      final loader = MonthOverview.debugLoader;
      final data = loader != null
          ? await loader(start, end)
          : await _apiService.exportTimesheet(
              startDate: start.toIso8601String(),
              endDate: end.toIso8601String(),
              userId: widget.user['id'],
            );
      // Trocou de mes no meio da leitura: descarta o resultado velho.
      if (!mounted || month != _month) return;
      setState(() {
        _days = (data['daily_records'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _summary = Map<String, dynamic>.from(data['summary'] as Map);
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || month != _month) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = _inPeriod(_today) ? _today : null;
    });
    _load();
  }

  // --- DERIVADOS ---

  /// Periodo da folha: 29 do mes anterior ate 28 do mes de referencia.
  /// O construtor do DateTime normaliza casos como "29 de fevereiro".
  DateTime get _periodStart => DateTime(_month.year, _month.month - 1, 29);
  DateTime get _periodEnd => DateTime(_month.year, _month.month, 28);
  // Dias contados pelo calendario (UTC nao tem horario de verao): com 24h
  // por dia, um dia de 23h tirava um dia do periodo.
  int get _periodDays =>
      DateTime.utc(_periodEnd.year, _periodEnd.month, _periodEnd.day)
          .difference(DateTime.utc(
              _periodStart.year, _periodStart.month, _periodStart.day))
          .inDays +
      1;
  DateTime _dateAt(int index) =>
      DateTime(_periodStart.year, _periodStart.month, _periodStart.day + index);

  double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  double _sum(String key) =>
      double.tryParse('${_summary[key] ?? 0}') ?? 0;

  bool get _isIntern => isInternProfile(widget.user);
  bool get _isDailyMode => widget.user['daily_mode'] == true;

  /// Saldo (esperado x trabalhado) so para o estagiario de ponto: a carga
  /// dele e fixa por dia util. Diaria e demais cargos seguem com o total.
  bool get _showBalance => _isIntern && !_isDailyMode;

  double get _dailyTarget {
    final v = double.tryParse('${widget.user['daily_hours'] ?? ''}');
    if (v != null && v > 0) return v;
    return _isIntern ? 6.0 : 8.0;
  }

  DateTime get _today {
    final n = _now;
    return DateTime(n.year, n.month, n.day);
  }

  /// Ultimo dia que entra no saldo: ontem no periodo em andamento (o dia de
  /// hoje ainda nao acabou), ou o fim do periodo nos meses fechados.
  DateTime get _cutoff {
    final yesterday = DateTime(_today.year, _today.month, _today.day - 1);
    return yesterday.isBefore(_periodEnd) ? yesterday : _periodEnd;
  }

  bool _inPeriod(DateTime d) =>
      !d.isBefore(_periodStart) && !d.isAfter(_periodEnd);

  /// Dia util do estagiario: segunda a sexta. O feriado CONTA: o
  /// estagiario nao folga a carga do feriado, ele compensa essas horas nos
  /// outros dias do periodo (regra da empresa, 27/10/2026).
  bool _isWorkday(DateTime d) => d.weekday <= DateTime.friday;

  String _key(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Map<String, dynamic>? _recordForDate(DateTime date) {
    final key = _key(date);
    final today = widget.todayRecord;
    if (today != null && today['date'] == key) return today;
    for (final d in _days) {
      if (d['date'] == key) return d;
    }
    return null;
  }

  double _workedOn(DateTime d) {
    final rec = _recordForDate(d);
    return rec == null ? 0 : _num(rec['total_hours']);
  }

  double _expectedOn(DateTime d) =>
      _isWorkday(d) && !d.isAfter(_cutoff) ? _dailyTarget : 0;

  /// Total do periodo pelos dias (o de hoje ja vem atualizado pela Dash).
  double get _total {
    var total = 0.0;
    for (var i = 0; i < _periodDays; i++) {
      total += _workedOn(_dateAt(i));
    }
    return total;
  }

  int get _workedDays {
    var count = 0;
    for (var i = 0; i < _periodDays; i++) {
      if (_workedOn(_dateAt(i)) > 0) count++;
    }
    return count;
  }

  List<_Week> get _weeks {
    final weeks = <_Week>[];
    var monday = DateTime(_periodStart.year, _periodStart.month,
        _periodStart.day - (_periodStart.weekday - 1));
    var running = 0.0;
    while (!monday.isAfter(_periodEnd)) {
      final days = List.generate(
          7, (i) => DateTime(monday.year, monday.month, monday.day + i));
      final inside = days.where(_inPeriod).toList();
      var worked = 0.0, counted = 0.0, expected = 0.0;
      for (final d in inside) {
        final w = _workedOn(d);
        worked += w;
        if (!d.isAfter(_cutoff)) counted += w;
        expected += _expectedOn(d);
      }
      final started = !inside.first.isAfter(_cutoff);
      final balance = counted - expected;
      if (started) running += balance;
      weeks.add(_Week(
        days: days,
        first: inside.first,
        last: inside.last,
        worked: worked,
        counted: counted,
        expected: expected,
        balance: balance,
        running: running,
        started: started,
      ));
      monday = DateTime(monday.year, monday.month, monday.day + 7);
    }
    return weeks;
  }

  String _hm(double hours) {
    final total = (hours * 60).round();
    return '${total ~/ 60}h ${(total % 60).toString().padLeft(2, '0')}m';
  }

  String _hmShort(double hours) {
    final total = (hours * 60).round();
    return '${total ~/ 60}h${(total % 60).toString().padLeft(2, '0')}';
  }

  String _signedHm(double hours) {
    if (hours.abs() < 5 / 60) return 'Em dia';
    return '${hours > 0 ? '+' : '−'}${_hm(hours.abs())}';
  }

  Color _balanceColor(double hours) {
    if (hours.abs() < 5 / 60) return _muted;
    return hours > 0 ? _green : _red;
  }

  // --- COMPOSICAO DAS HORAS ---
  // Pelos dias (o de hoje ja vem atualizado pela Dash), para fechar com o
  // total do mes. A regra e a da folha (classifyWorkMinutes):
  //   - domingo, feriado e 22h-5h: extra 100%
  //   - sabado: extra 50%
  //   - dia util: normal. Estagiario: normal so das 13:30 as 19:30; o resto
  //     e "fora do horario".

  double _regularOn(Map<String, dynamic> rec) {
    if (rec['regular_hours'] != null) return _num(rec['regular_hours']);
    return _num(rec['total_hours']) - _num(rec['overtime_hours']);
  }

  ({double regular, double outside, double e50, double e100}) get _composition {
    var regular = 0.0, outside = 0.0, e50 = 0.0, e100 = 0.0;
    for (var i = 0; i < _periodDays; i++) {
      final rec = _recordForDate(_dateAt(i));
      if (rec == null) continue;
      final a = _num(rec['extra_50']);
      final b = _num(rec['extra_100']);
      regular += _regularOn(rec);
      e50 += a;
      e100 += b;
      outside += (_num(rec['overtime_hours']) - a - b).clamp(0, 24);
    }
    return (regular: regular, outside: outside, e50: e50, e100: e100);
  }

  /// Dias com horas no periodo, do mais antigo ao mais novo.
  List<(DateTime, double)> get _workedList => [
        for (var i = 0; i < _periodDays; i++)
          if (_workedOn(_dateAt(i)) > 0) (_dateAt(i), _workedOn(_dateAt(i))),
      ];

  /// Media do horario de entrada, em minutos desde a meia-noite.
  int? get _avgCheckIn {
    final mins = <int>[];
    for (var i = 0; i < _periodDays; i++) {
      final raw = _recordForDate(_dateAt(i))?['check_in'];
      if (raw is! String || !raw.contains(':')) continue;
      final parts = raw.split(':');
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h == null || m == null) continue;
      mins.add(h * 60 + m);
    }
    if (mins.isEmpty) return null;
    return (mins.reduce((a, b) => a + b) / mins.length).round();
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMonthSwitcher(),
        const SizedBox(height: 12),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: wineColor)),
          )
        else if (_error != null)
          _buildError()
        else ...[
          if (_showBalance) _buildBalanceHero() else _buildTotalHero(),
          const SizedBox(height: 16),
          _buildStatTiles(),
          const SizedBox(height: 16),
          _buildComposition(),
          const SizedBox(height: 16),
          _buildCalendar(),
          const SizedBox(height: 16),
          _buildHighlights(),
        ],
      ],
    );
  }

  Widget _card({required Widget child, EdgeInsets? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withOpacity(0.08)
              : Colors.black.withOpacity(0.06),
        ),
      ),
      child: child,
    );
  }

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          color: _muted,
          fontSize: 10,
          letterSpacing: 1.2,
          fontWeight: FontWeight.bold));

  Widget _buildError() {
    return _card(
      child: Column(
        children: [
          const Icon(Icons.cloud_off, size: 32, color: Colors.grey),
          const SizedBox(height: 8),
          const Text('Não foi possível carregar o mês',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('$_error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('Tentar de novo')),
        ],
      ),
    );
  }

  Widget _buildMonthSwitcher() {
    final label = DateFormat('MMMM yyyy', 'pt_BR').format(_month);
    final now = _now;
    // Periodo atual: a partir do dia 29 ja conta o mes seguinte.
    final currentPeriod = now.day >= 29
        ? DateTime(now.year, now.month + 1)
        : DateTime(now.year, now.month);
    final isCurrent = !_month.isBefore(currentPeriod);
    final range = '${DateFormat('dd/MM').format(_periodStart)} a '
        '${DateFormat('dd/MM').format(_periodEnd)}';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          onPressed: () => _shiftMonth(-1),
          icon: const Icon(Icons.chevron_left),
          tooltip: 'Mês anterior',
        ),
        Column(
          children: [
            Text(
              '${label[0].toUpperCase()}${label.substring(1)}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(range, style: const TextStyle(fontSize: 11, color: _muted)),
          ],
        ),
        IconButton(
          onPressed: isCurrent ? null : () => _shiftMonth(1),
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Próximo mês',
        ),
      ],
    );
  }

  /// Quem faz o proprio horario: o total do mes e as extras, sem meta.
  Widget _buildTotalHero() {
    final e50 = _sum('total_50');
    final e100 = _sum('total_100');
    final extras = _sum('total_extras') + e50 + e100;
    return _card(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('HORAS NO MÊS'),
          const SizedBox(height: 6),
          Text(_hm(_total),
              style: const TextStyle(
                  fontSize: 36,
                  height: 1.1,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(height: 4),
          Text(
              _workedDays == 1
                  ? 'em 1 dia trabalhado'
                  : 'em $_workedDays dias trabalhados',
              style: const TextStyle(fontSize: 13, color: _muted)),
          // Diaria e o dia padrao da folha: nao tem extra.
          if (!_isDailyMode) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.more_time, size: 18, color: _orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      const TextSpan(text: 'Horas extras: '),
                      TextSpan(
                          text: _hm(extras),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (extras > 0)
                        TextSpan(
                            text: '  (50%: ${_hm(e50)} · 100%: ${_hm(e100)})',
                            style: const TextStyle(color: _muted)),
                    ]),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Quatro numeros do mes: dias, media, extras e entrada media.
  Widget _buildStatTiles() {
    final c = _composition;
    final extras = c.outside + c.e50 + c.e100;
    final worked = _workedList;
    final avg = worked.isEmpty ? 0.0 : _total / worked.length;
    final entry = _avgCheckIn;
    final tiles = [
      ('DIAS TRABALHADOS', '${worked.length}', 'de $_periodDays dias'),
      ('MÉDIA POR DIA', _hm(avg), 'nos dias com registro'),
      ('HORAS EXTRAS', _hm(extras),
          _isIntern ? 'fora do horário, 50% e 100%' : '50% + 100%'),
      (
        'ENTRADA MÉDIA',
        entry == null
            ? '--:--'
            : '${(entry ~/ 60).toString().padLeft(2, '0')}:'
                '${(entry % 60).toString().padLeft(2, '0')}',
        'horário típico'
      ),
    ];
    return LayoutBuilder(builder: (context, box) {
      final twoCols = box.maxWidth < 560;
      final w = twoCols ? (box.maxWidth - 12) / 2 : (box.maxWidth - 36) / 4;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final (label, value, hint) in tiles)
            SizedBox(
              width: w,
              child: _card(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: _muted,
                            fontSize: 9,
                            letterSpacing: 1,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            fontFeatures: [FontFeature.tabularFigures()])),
                    const SizedBox(height: 2),
                    Text(hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 10)),
                  ],
                ),
              ),
            ),
        ],
      );
    });
  }

  /// Quanto do mes foi hora normal e quanto foi extra, e por que. Para quem
  /// faz o proprio horario toda hora conta: a extra e so o adicional da
  /// folha (sabado, domingo, feriado, madrugada), nao uma hora proibida.
  Widget _buildComposition() {
    final c = _composition;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final rows = [
      (
        'Normal',
        _isIntern ? 'dia útil, 13:30 às 19:30' : 'dia útil, 5h às 22h',
        c.regular,
        dark ? const Color(0xFF3987E5) : const Color(0xFF2A78D6),
      ),
      if (_isIntern)
        (
          'Fora do horário',
          'dia útil, fora das 13:30 às 19:30',
          c.outside,
          dark ? const Color(0xFFD9A21B) : const Color(0xFFC98A00),
        ),
      (
        'Extra 50%',
        'sábado',
        c.e50,
        dark ? const Color(0xFFD95926) : const Color(0xFFEB6834),
      ),
      (
        'Extra 100%',
        'domingo, feriado e 22h às 5h',
        c.e100,
        dark ? const Color(0xFF199E70) : const Color(0xFF1BAF7A),
      ),
    ];
    final sum = rows.fold<double>(0, (p, r) => p + r.$3);
    final track = dark ? const Color(0xFF2C2C2A) : const Color(0xFFE1E0D9);

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('COMPOSIÇÃO DAS HORAS'),
          const SizedBox(height: 4),
          Text(
              _isIntern
                  ? 'Seu horário é das 13:30 às 19:30. Fora dele, só com liberação do gestor.'
                  : 'Toda hora trabalhada conta. Sábado, domingo, feriado e madrugada têm adicional.',
              style: const TextStyle(fontSize: 12, color: _muted)),
          const SizedBox(height: 14),
          for (final (name, why, hours, color) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: color, borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 132,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(why,
                            maxLines: 2,
                            style:
                                const TextStyle(fontSize: 10, color: _muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: sum <= 0 ? 0 : hours / sum,
                        minHeight: 6,
                        backgroundColor: track,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 64,
                    child: Text(_hm(hours),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// O dia mais longo, quantos dias tiveram registro e o ritmo medio.
  Widget _buildHighlights() {
    final worked = _workedList;
    final avg = worked.isEmpty ? 0.0 : _total / worked.length;
    final best = worked.isEmpty
        ? null
        : worked.reduce((a, b) => a.$2 >= b.$2 ? a : b);

    Widget line(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: wineColor),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
              Text(value,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold)),
            ],
          ),
        );

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('DESTAQUES'),
          const SizedBox(height: 14),
          if (best != null)
            line(Icons.local_fire_department, 'Dia mais longo',
                '${DateFormat('dd/MM').format(best.$1)} · ${_hm(best.$2)}'),
          line(Icons.event_available, 'Dias com registro',
              '${worked.length} de $_periodDays'),
          line(Icons.speed, 'Ritmo médio', '${_hm(avg)} por dia trabalhado'),
        ],
      ),
    );
  }

  /// Estagiario: o saldo ate ontem (ou do periodo fechado) e quanto falta
  /// para fechar o periodo em dia.
  Widget _buildBalanceHero() {
    var counted = 0.0, expected = 0.0, worked = 0.0, fullExpected = 0.0;
    var countedDays = 0, remainingDays = 0;
    for (var i = 0; i < _periodDays; i++) {
      final d = _dateAt(i);
      final w = _workedOn(d);
      worked += w;
      if (!d.isAfter(_cutoff)) counted += w;
      final exp = _expectedOn(d);
      expected += exp;
      if (exp > 0) countedDays++;
      if (_isWorkday(d)) {
        fullExpected += _dailyTarget;
        if (d.isAfter(_cutoff)) remainingDays++;
      }
    }
    final balance = counted - expected;
    final closed = !_cutoff.isBefore(_periodEnd);
    final color = _balanceColor(balance);
    final pct =
        fullExpected <= 0 ? 0.0 : (worked / fullExpected).clamp(0.0, 1.0);
    final caption = balance.abs() < 5 / 60
        ? 'Nem sobrando nem faltando hora.'
        : balance > 0
            ? 'Você trabalhou a mais do que o esperado.'
            : 'Faltam essas horas para completar o esperado.';
    final missing = fullExpected - worked;

    return _card(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(closed ? 'SALDO DO MÊS' : 'SEU SALDO ATÉ ONTEM'),
          const SizedBox(height: 6),
          Text(_signedHm(balance),
              style: TextStyle(
                  fontSize: 36,
                  height: 1.1,
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 4),
          Text(caption,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          const SizedBox(height: 8),
          Text(
            'Trabalhou ${_hm(counted)} de ${_hm(expected)} esperadas '
            '($countedDays dias úteis × ${_hm(_dailyTarget)}, feriado incluído).',
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _label('MÊS INTEIRO'),
              const Spacer(),
              Text('${_hm(worked)} de ${_hm(fullExpected)}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: _muted.withOpacity(0.2),
              valueColor: const AlwaysStoppedAnimation<Color>(_blue),
            ),
          ),
          if (!closed && remainingDays > 0) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(missing <= 5 / 60 ? Icons.check_circle : Icons.flag,
                    size: 18, color: missing <= 5 / 60 ? _green : _blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    missing <= 5 / 60
                        ? 'O mês já está completo.'
                        : remainingDays == 1
                            ? 'Para fechar o mês em dia: ${_hm(missing)} '
                                'no último dia útil.'
                            : 'Para fechar o mês em dia: ${_hm(missing / remainingDays)} '
                                'por dia nos $remainingDays dias úteis que faltam.',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCalendar() {
    final weeks = _weeks;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('HORAS POR DIA'),
          const SizedBox(height: 4),
          Text(
            _showBalance
                ? 'Esperado: ${_hm(_dailyTarget)} por dia útil (segunda a sexta). '
                    'Toque num dia para ver os horários.'
                : 'Toque num dia para ver os horários.',
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          if (_showBalance) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _legend(_green, 'completo'),
                _legend(_orange, 'abaixo'),
                _legend(_red, 'falta'),
                _legend(_purple, 'feriado (a compensar)'),
              ],
            ),
          ],
          const SizedBox(height: 12),
          for (var i = 0; i < weeks.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _buildWeek(i + 1, weeks[i]),
          ],
          if (_selected != null && _inPeriod(_selected!)) ...[
            const SizedBox(height: 16),
            _buildDayDetail(_selected!),
          ],
        ],
      ),
    );
  }

  Widget _legend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              color: color.withOpacity(0.18),
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _buildWeek(int number, _Week w) {
    final range = '${DateFormat('dd/MM').format(w.first)} a '
        '${DateFormat('dd/MM').format(w.last)}';
    final showChip = _showBalance && w.started && w.expected + w.counted > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Semana $number',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(range,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _muted)),
            ),
            if (showChip)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: _balanceColor(w.balance).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(_signedHm(w.balance),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _balanceColor(w.balance),
                        fontFeatures: const [FontFeature.tabularFigures()])),
              )
            else if (!_showBalance)
              Text(_hm(w.worked),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final d in w.days)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _buildDayCell(d),
                ),
              ),
          ],
        ),
      ],
    );
  }

  static const _weekdayLetters = ['S', 'T', 'Q', 'Q', 'S', 'S', 'D'];

  Widget _buildDayCell(DateTime d) {
    final letter = _weekdayLetters[d.weekday - 1];
    final inside = _inPeriod(d);
    final worked = _workedOn(d);
    final isToday = d == _today;
    final isSelected = d == _selected;
    final future = d.isAfter(_today);
    final holiday = isHoliday(d);
    final workday = _isWorkday(d);

    // Rotulo e cor do dia. Sem meta (quem faz o proprio horario): dia com
    // hora em azul, o resto neutro; "falta" e "abaixo" so no estagiario.
    String label;
    Color? color;
    if (!inside) {
      label = '';
    } else if (worked > 0) {
      label = _hmShort(worked);
      if (!_showBalance) {
        color = _blue;
      } else if (!workday || worked >= _dailyTarget - 5 / 60) {
        color = _green;
      } else if (isToday) {
        color = _blue;
      } else {
        color = _orange;
      }
    } else if (holiday) {
      label = 'fer.';
      color = _purple;
    } else if (_showBalance && workday && !future && !isToday) {
      label = 'falta';
      color = _red;
    } else {
      label = '–';
    }

    final cell = Container(
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isSelected
            ? wineColor.withOpacity(0.22)
            : color == null
                ? Colors.transparent
                : color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isToday || isSelected
              ? wineColor
              : (color ?? _muted).withOpacity(color == null ? 0.3 : 0.6),
          width: isToday || isSelected ? 2 : 1,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('${d.day}', style: const TextStyle(fontSize: 10, color: _muted)),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );

    return Opacity(
      opacity: inside ? 1 : 0.3,
      child: Column(
        children: [
          Text(letter,
              style: const TextStyle(
                  fontSize: 10, color: _muted, fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          inside
              ? InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _selected = d),
                  child: cell,
                )
              : cell,
        ],
      ),
    );
  }

  /// O dia tocado: horas e os horarios trabalhados, como na folha.
  Widget _buildDayDetail(DateTime d) {
    final rec = _recordForDate(d);
    final worked = _workedOn(d);
    final title = DateFormat("EEEE, dd/MM", 'pt_BR').format(d);
    final periods = <String>[];
    if (rec != null) {
      for (final (start, end) in const [
        ('check_in', 'check_out'),
        ('break_start', 'break_end'),
        ('entry_3', 'exit_3'),
      ]) {
        final from = rec[start]?.toString();
        if (from == null || from.isEmpty) continue;
        final to = rec[end]?.toString();
        periods.add(to == null || to.isEmpty ? '$from – agora' : '$from – $to');
      }
    }
    final extras = rec == null ? 0.0 : _num(rec['overtime_hours']);

    String message;
    if (worked > 0 || periods.isNotEmpty) {
      message = '';
    } else if (isHoliday(d)) {
      message = 'Feriado.';
    } else if (d.isAfter(_today)) {
      message = 'Dia ainda não chegou.';
    } else {
      message = 'Sem ponto neste dia.';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: wineColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: wineColor.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${title[0].toUpperCase()}${title.substring(1)}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              if (worked > 0)
                Text(_hm(worked),
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 6),
          if (message.isNotEmpty)
            Text(message, style: const TextStyle(fontSize: 13, color: _muted))
          else ...[
            Text(
              _isDailyMode
                  ? 'Diária (horário padrão): ${periods.join('  ·  ')}'
                  : 'Trabalhou: ${periods.join('  ·  ')}',
              style: const TextStyle(fontSize: 13),
            ),
            if (!_isDailyMode && extras > 0) ...[
              const SizedBox(height: 4),
              Text('Horas extras neste dia: ${_hm(extras)}',
                  style: const TextStyle(fontSize: 12, color: _orange)),
            ],
          ],
        ],
      ),
    );
  }
}

/// Uma semana (segunda a domingo) recortada no periodo da folha.
class _Week {
  const _Week({
    required this.days,
    required this.first,
    required this.last,
    required this.worked,
    required this.counted,
    required this.expected,
    required this.balance,
    required this.running,
    required this.started,
  });

  final List<DateTime> days;
  final DateTime first;
  final DateTime last;

  /// Tudo o que foi trabalhado na semana, inclusive hoje.
  final double worked;

  /// Trabalhado ate ontem (o que entra no saldo).
  final double counted;
  final double expected;
  final double balance;

  /// Saldo do mes acumulado ate o fim desta semana.
  final double running;

  /// A semana ja comecou (tem dia ate ontem).
  final bool started;
}
