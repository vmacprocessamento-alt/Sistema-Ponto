import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../utils/shift_records.dart';
import '../widgets/startup_loading.dart';
import '../widgets/user_notification_bell.dart';

import 'user_chat_list_screen.dart';

/// Como fechar um turno aberto de outro dia: saida agora (turno da noite) ou
/// saida esquecida (fecha sem horas, o gestor corrige).
enum _CarriedExit { now, forgot }

/// Batidas que a tela libera no estado atual: o botao principal (entrada,
/// pausa ou retorno) e se a saida vale.
class _PunchOptions {
  const _PunchOptions(this.mainAction, this.mainLabel, this.canExit);

  final String? mainAction;
  final String mainLabel;
  final bool canExit;

  bool allows(String type) =>
      type == mainAction || (canExit && type == 'check_out');
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _apiService = ApiService();
  String _currentTime = "";
  String _currentDate = "";
  bool _isLoading = true;
  List<dynamic> _todayRecords = [];
  // Todos os pontos da janela de 14 dias (ordem cronologica), para as regras
  // que dependem do dia de trabalho e nao so da data do ponto.
  List<Map<String, dynamic>> _windowRecords = [];
  DateTime? _lastRecordsLoad;
  // Pausa ja fechada automaticamente nesta sessao: se a lista nao recarregar,
  // o timer de 1s nao tenta fechar a mesma pausa de novo a cada segundo.
  String? _autoClosedBreakKey;
  String _currentStatus = "Carregando...";
  String _lastActionTime = "";
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Map<String, dynamic>? _user;
  bool _isAutoClosingBreak = false;
  bool _isSyncingOffline = false;
  bool _punchInFlight = false;
  int _pendingOfflineRecordsCount = 0;
  // Pontos da fila que o servidor recusou (ficam parados, nao reenviam
  // sozinhos) e o motivo do primeiro, para o aviso.
  int _blockedOfflineRecordsCount = 0;
  String? _blockedOfflineReason;
  // Dos recusados, os que so esperam a liberacao do gestor (saida depois do
  // limite da hora extra): liberada, a mesma batida passa.
  int _awaitingApprovalOfflineRecordsCount = 0;
  // Pedidos de hora extra liberados para os quais a fila ja foi reenviada.
  final Set<String> _retriedApprovalIds = {};
  DateTime? _lastOfflineSyncAttempt;
  String? _lastInternReminderDate;
  // Entrada de um turno que comecou em um dia anterior e nunca foi fechado
  // (turno da noite ou saida esquecida, e o dia virou). Null quando nao ha.
  DateTime? _carriedOpenShiftStart;
  // Id dessa entrada: a saida esquecida usa "forgot_<id>".
  String? _carriedOpenShiftId;
  // Dia (yyyy-MM-dd) dos pontos carregados; quando o relogio vira o dia com o
  // app aberto, a tela recarrega.
  String? _recordsDayKey;
  Map<String, dynamic> _effectiveSchedule = const {
    'shift_start': '13:30',
    'shift_end': '19:30',
    'start_allowed_from': '13:25',
    'start_allowed_until': '19:25',
    'overtime_prompt_after': '19:35',
    'timezone': 'America/Sao_Paulo',
  };
  Map<String, dynamic>? _scheduleState;
  DateTime? _lastScheduleRefresh;
  bool _refreshingSchedule = false;
  // shift_day (yyyy-MM-dd, ou '' sem turno aberto) usado no ultimo horario
  // lido; null enquanto nenhum foi lido.
  String? _scheduleShiftDay;
  // A ultima leitura do horario nao alcancou o servidor (copia do aparelho
  // ou falha de rede): a liberacao da hora extra pode ja existir la.
  bool _workScheduleOffline = false;

  // Cores da Empresa
  static const Color wineColor = Color(0xFF8B0000);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateTime();
    _timer =
        Timer.periodic(const Duration(seconds: 1), (timer) => _updateTime());
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        unawaited(_trySyncOfflineRecords(showMessage: true));
      }
    });
    _loadInitialData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _user == null) return;
    // O app volta do segundo plano mostrando o estado de quando saiu (a
    // saida pode ter sido batida no PC nesse meio tempo). Recarrega se a
    // ultima leitura ja tem mais de 2 minutos.
    final last = _lastRecordsLoad;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 2)) {
      return;
    }
    unawaited(_refreshAfterResume());
  }

  Future<void> _refreshAfterResume() async {
    await _trySyncOfflineRecords();
    await _loadTodayRecords();
  }

  void _updateTime() {
    final now = DateTime.now();
    if (mounted) {
      setState(() {
        _currentTime = DateFormat('HH:mm:ss').format(now);
        _currentDate =
            DateFormat('EEEE, d MMMM yyyy', 'pt_BR').format(now).toUpperCase();
      });
      _checkAutoActions(now);
      // App aberto de um dia para o outro: sem recarregar, a tela seguia com
      // os pontos da vespera como se fossem de hoje.
      final dayKey = DateFormat('yyyy-MM-dd').format(now);
      if (_recordsDayKey != null && _recordsDayKey != dayKey) {
        _recordsDayKey = dayKey;
        unawaited(_loadTodayRecords());
      }
      if (_user != null &&
          (_lastOfflineSyncAttempt == null ||
              now.difference(_lastOfflineSyncAttempt!).inSeconds >= 60)) {
        _lastOfflineSyncAttempt = now;
        unawaited(_trySyncOfflineRecords());
      }
      // Refresh de fundo espacado (90s): cada refresh le pontos do Firestore.
      // A meta de 30s deixava as leituras muito altas para a cota gratuita.
      // Bater ponto ja recarrega na hora; o pull-to-refresh tambem.
      if (_isInternUser &&
          !_refreshingSchedule &&
          (_lastScheduleRefresh == null ||
              now.difference(_lastScheduleRefresh!).inSeconds >= 90)) {
        _lastScheduleRefresh = now;
        unawaited(_refreshWorkSchedule(refreshRecords: true));
      }
    }
  }

  void _checkAutoActions(DateTime now) {
    // 1. Fechamento automatico de pausa apos 3h aberta.
    if (_todayRecords.isNotEmpty && !_isAutoClosingBreak) {
      final last = _todayRecords.last;
      if ((last['record_type'] == 'break_start' ||
              last['record_type'] == 'entry_3') &&
          _breakKey(last) != _autoClosedBreakKey) {
        final startTime = DateTime.parse(last['timestamp']);
        final diff = now.difference(startTime).inMinutes;

        if (diff >= 180) {
          _autoCloseBreak(last);
        }
      }
    }

    // 2. Aviso no limite configurado para o estagiario.
    bool isEstagiario = _isInternUser;

    final todayKey = DateFormat('yyyy-MM-dd').format(now);
    final reminder = _dateAtConfiguredTime(now, 'overtime_prompt_after');
    if (isEstagiario &&
        _hasOpenPoint &&
        !now.isBefore(reminder) &&
        _lastInternReminderDate != todayKey) {
      _lastInternReminderDate = todayKey;
      unawaited(_notifyInternIfPointIsOpen());
    }
  }

  String _breakKey(dynamic breakStart) =>
      (breakStart['id'] ?? breakStart['timestamp']).toString();

  Future<void> _autoCloseBreak(dynamic breakStart) async {
    _isAutoClosingBreak = true;
    final String returnType =
        breakStart['record_type'] == 'break_start' ? 'break_end' : 'exit_3';
    final closedAt = DateTime.parse(breakStart['timestamp'].toString())
        .add(const Duration(hours: 1));
    final breakStartId = breakStart['id']?.toString() ?? '';

    try {
      // Confere no servidor antes de gravar: a lista pode ser a copia local
      // da abertura ou de antes do segundo plano, e o retorno pode ter sido
      // batido em outro aparelho. Sem isso gravava um retorno automatico ao
      // lado do real, com aviso de "Pausa Encerrada" falso.
      await _loadTodayRecords();
      final last = _todayRecords.isEmpty ? null : _todayRecords.last;
      if (last == null ||
          _breakKey(last) != _breakKey(breakStart) ||
          DateTime.now()
                  .difference(DateTime.parse(last['timestamp'].toString())) <
              const Duration(hours: 3)) {
        return;
      }
      await _apiService.createTimeRecord(
        recordType: returnType,
        timestamp: closedAt.toIso8601String(),
        notes: "Retorno automatico (pausa excedeu 3h; ajustado para 1h)",
        location: "Sistema (Auto)",
        // Mesmo id do job do backend que fecha pausas esquecidas: o job, este
        // aparelho e qualquer outro gravam o MESMO retorno, nunca dois.
        recordId: breakStartId.isEmpty ? null : 'autoclose_$breakStartId',
        extraFields: const {'auto_closed': true},
      );
      _autoClosedBreakKey = _breakKey(breakStart);
      // Recarrega logo depois de gravar: enquanto a lista mostrar a pausa
      // aberta, o timer de 1s chama esta funcao de novo. No web o aviso abaixo
      // lancava excecao antes do recarregamento e um retorno novo era gravado
      // a cada segundo.
      await _loadTodayRecords();
    } catch (e) {
      debugPrint('Erro no auto-close: $e');
      return;
    } finally {
      _isAutoClosingBreak = false;
    }

    try {
      await NotificationService.showBreakAutoClosed(closedAt: closedAt);
    } catch (e) {
      debugPrint('Aviso de pausa fechada indisponivel: $e');
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pausa Encerrada'),
        content: const Text(
            'Sua pausa excedeu 3h e foi fechada automaticamente com 1 hora de pausa.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'))
        ],
      ),
    );
  }

  bool get _isInternUser {
    final role = (_user?['role'] ?? '').toString().toLowerCase();
    return role.contains('estag') || role.contains('intern');
  }

  /// Ha turno aberto: o da vespera ou uma entrada de hoje sem saida. Pelo
  /// ultimo ponto, as pausas soltas de uma entrada recusada na sincronizacao
  /// (a entrada sai da tela, as pausas ficam) pareciam turno aberto: sem
  /// REGISTRAR ENTRADA, so FINALIZAR, que o backend recusava.
  bool get _hasOpenPoint =>
      _carriedOpenShiftStart != null || openShiftCheckIn(_todayRecords) != null;

  DateTime _dateAtConfiguredTime(DateTime day, String field) {
    final parts = (_effectiveSchedule[field] ?? '').toString().split(':');
    final hour = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return DateTime(day.year, day.month, day.day, hour, minute);
  }

  String? get _overtimeRequestStatus {
    final request = _scheduleState?['overtime_request'];
    if (request is Map) return request['status']?.toString();
    return null;
  }

  /// Hora do pedido de entrada fora do horario feito hoje que ainda aguarda
  /// um gestor, ou null.
  DateTime? get _pendingStartRequestAt {
    final request = _scheduleState?['start_request'];
    if (request is! Map || request['status'] != 'pending') return null;
    final at =
        DateTime.tryParse(request['attempted_at']?.toString() ?? '')?.toLocal();
    final now = DateTime.now();
    if (at == null ||
        at.year != now.year ||
        at.month != now.month ||
        at.day != now.day) {
      return null;
    }
    return at;
  }

  bool get _isOvertimeDecisionRequired {
    if (!_isInternUser || !_hasOpenPoint) return false;
    if (_overtimeRequestStatus == 'approved') return false;
    final shiftStart = _currentShiftStartDate();
    if (shiftStart == null) return false;
    final threshold =
        _dateAtConfiguredTime(shiftStart, 'overtime_prompt_after');
    return !DateTime.now().isBefore(threshold);
  }

  Future<void> _configureInternReminder() async {
    if (!_isInternUser || !_hasOpenPoint) {
      await NotificationService.cancelInternOpenPointReminder();
      return;
    }

    final now = DateTime.now();
    await NotificationService.scheduleInternOpenPointReminder(
      now,
      scheduledAt: _dateAtConfiguredTime(now, 'overtime_prompt_after'),
    );
  }

  Future<void> _notifyInternIfPointIsOpen() async {
    await _loadTodayRecords();
    if (!_isInternUser || !_hasOpenPoint) return;

    await NotificationService.showInternOpenPointReminder();
  }

  String get _displayUserName {
    final name = (_user?['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;

    final email = (_user?['email'] ?? '').toString().trim();
    if (email.isNotEmpty) return email;

    return 'Carregando...';
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);

    // 1) Copia local primeiro: a tela de ponto aparece na hora, com ou sem
    // internet. Antes ela esperava perfil + horario + fila + pontos do
    // servidor; no iPhone, depois de fechar e reabrir o app, isso ficava
    // girando sem fim.
    try {
      final cachedUser = await _apiService.getCachedCurrentUser();
      // Sem copia local ainda (primeira abertura depois da atualizacao), a
      // tela mostraria "Aguardando entrada" para quem ja bateu a entrada;
      // nesse caso continua esperando o servidor, como antes.
      if (cachedUser != null && await _apiService.hasLocalTimeRecordsCache()) {
        _user = cachedUser;
        await _loadTodayRecords(localOnly: true);
        await _restoreCachedWorkSchedule();
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('Copia local indisponivel: $e');
    }

    // 2) Atualiza com o servidor em segundo plano.
    try {
      final user = await _apiService.getCurrentUser();
      _user = user;
      await _refreshWorkSchedule();
      await _trySyncOfflineRecords();
      await _loadTodayRecords();
    } catch (e) {
      debugPrint('Erro init: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshWorkSchedule({bool refreshRecords = false}) async {
    if (!_isInternUser || _refreshingSchedule) return;
    _refreshingSchedule = true;
    try {
      // Turno aberto que virou a meia-noite: a liberacao de hora extra esta
      // no dia em que ele comecou.
      final shiftDay = _hasOpenPoint ? _currentShiftStartDate() : null;
      final shiftDayKey = _openShiftDayKey();
      final state =
          await _apiService.getEffectiveWorkSchedule(shiftDay: shiftDay);
      final schedule = state['schedule'];
      if (mounted && schedule is Map) {
        setState(() {
          _scheduleState = state;
          _effectiveSchedule = Map<String, dynamic>.from(schedule);
          _workScheduleOffline = state['from_cache'] == true;
        });
        _scheduleShiftDay = shiftDayKey;
      }
      if (refreshRecords) await _loadTodayRecords();
    } catch (e) {
      debugPrint('Horario efetivo indisponivel: $e');
      if (mounted && ApiService.isNetworkFailure(e)) {
        setState(() => _workScheduleOffline = true);
      }
    } finally {
      _refreshingSchedule = false;
    }
    await _retryExitsAwaitingApproval();
  }

  /// A saida guardada no aparelho que o servidor recusou por falta da
  /// liberacao da hora extra sai sozinha quando o gestor libera. A
  /// sincronizacao automatica para nas recusadas e nada a reenviava: a tela
  /// mostrava o turno aberto de novo e, batida outra saida, pagava ate ela.
  /// Uma vez por liberacao (lida do servidor), depois de o servidor responder.
  Future<void> _retryExitsAwaitingApproval() async {
    final request = _scheduleState?['overtime_request'];
    if (!mounted ||
        _workScheduleOffline ||
        request is! Map ||
        request['status'] != 'approved') {
      return;
    }
    final requestId = request['id']?.toString() ?? '';
    if (requestId.isEmpty || _retriedApprovalIds.contains(requestId)) return;
    final queued = await _apiService.getCurrentUserOfflineRecords();
    if (!queued.any((record) =>
        record['record_type'] == 'check_out' &&
        ApiService.isAwaitingApprovalOfflineRecord(record))) {
      return;
    }
    await ApiService.waitForOfflineSync();
    final before = await _apiService.getCurrentUserOfflineRecords();
    if (!await _trySyncOfflineRecords(showMessage: true, retryBlocked: true)) {
      return;
    }
    // So conta como reenviada quando o servidor respondeu
    // (awaitingApprovalRetryAnswered); senao o proximo refresh tenta de
    // novo. Marcada mesmo quando o reenvio nao chegava (timeout no sinal
    // fraco), nada mais reenviava a saida nesta sessao e o aviso seguia
    // dizendo que o envio era automatico.
    if (ApiService.awaitingApprovalRetryAnswered(
        before, await _apiService.getCurrentUserOfflineRecords())) {
      _retriedApprovalIds.add(requestId);
    }
  }

  /// Abertura sem internet: o horario e a liberacao da hora extra lidos da
  /// ultima vez neste aparelho, antes de qualquer consulta. So na memoria, o
  /// estagiario com a hora extra liberada abria travado na tela de horario
  /// encerrado.
  Future<void> _restoreCachedWorkSchedule() async {
    if (!_isInternUser) return;
    final state = await _apiService.getCachedEffectiveWorkSchedule(
        shiftDay: _hasOpenPoint ? _currentShiftStartDate() : null);
    final schedule = state?['schedule'];
    if (!mounted || state == null || schedule is! Map) return;
    setState(() {
      _scheduleState = state;
      _effectiveSchedule = Map<String, dynamic>.from(schedule);
    });
    _scheduleShiftDay = _openShiftDayKey();
  }

  /// Dia (yyyy-MM-dd) do turno aberto, o shift_day do horario; '' sem turno.
  String _openShiftDayKey() {
    final start = _hasOpenPoint ? _currentShiftStartDate() : null;
    return start == null ? '' : DateFormat('yyyy-MM-dd').format(start);
  }

  /// Conta a fila do usuario: total e os recusados pelo servidor.
  void _applyOfflineCounts(List<Map<String, dynamic>> pendingRecords) {
    final blocked =
        pendingRecords.where(ApiService.isBlockedOfflineRecord).toList();
    _pendingOfflineRecordsCount = pendingRecords.length;
    _blockedOfflineRecordsCount = blocked.length;
    _awaitingApprovalOfflineRecordsCount = blocked
        .where(ApiService.isAwaitingApprovalOfflineRecord)
        .length;
    // Motivo para o aviso dos recusados por outra regra.
    final other = blocked
        .where((record) => !ApiService.isAwaitingApprovalOfflineRecord(record))
        .toList();
    _blockedOfflineReason =
        other.isEmpty ? null : other.first['sync_error']?.toString();
  }

  Future<void> _loadTodayRecords({bool localOnly = false}) async {
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day).toIso8601String();
      // Ate o ultimo microssegundo: com 23:59:59 cravado, um ponto das
      // 23:59:59.500 ficava de fora.
      final end = DateTime(now.year, now.month, now.day, 23, 59, 59, 999, 999)
          .toIso8601String();

      // Janela de 14 dias para todos os cargos (turno que atravessou o dia),
      // e ela ja contem o dia de hoje: uma consulta so serve as duas coisas.
      // So hoje, a entrada das 19:30 sumia da tela a meia-noite e o app
      // liberava uma nova entrada com o turno anterior ainda aberto.
      final todayMidnight = DateTime(now.year, now.month, now.day);
      final windowStart =
          todayMidnight.subtract(const Duration(days: 14)).toIso8601String();
      final windowRecords =
          await _apiService.getTimeRecords(
              startDate: windowStart, endDate: end, localOnly: localOnly);
      final carried = _carriedOpenShift(todayMidnight, windowRecords);
      // Com turno aberto de outro dia, a tela segue o turno desde a entrada:
      // status, pausas e saida valem para ele, nao so para os pontos de hoje.
      final from = carried?['timestamp']?.toString() ?? start;
      final records = windowRecords.where((item) {
        final timestamp = (item as Map)['timestamp'].toString();
        return timestamp.compareTo(from) >= 0;
      }).toList();
      final pendingRecords = await _apiService.getCurrentUserOfflineRecords();

      if (!mounted) return;
      setState(() {
        _recordsDayKey = DateFormat('yyyy-MM-dd').format(now);
        _carriedOpenShiftStart = carried == null
            ? null
            : DateTime.tryParse(carried['timestamp'].toString());
        _carriedOpenShiftId = carried?['id']?.toString();
        _windowRecords = windowRecords
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList()
            .reversed
            .toList();
        _todayRecords = records.reversed.toList(); // Ordem cronológica
        _applyOfflineCounts(pendingRecords);
        _updateStatus();
      });
      if (!localOnly) _lastRecordsLoad = now;
      unawaited(_configureInternReminder());
      // O horario lido antes dos pontos (abertura sem copia local) ou antes
      // de o turno mudar procura a liberacao de hora extra no dia errado: um
      // turno de ontem ja liberado mostrava "HORARIO PROGRAMADO ENCERRADO"
      // ate o proximo refresh, 90s depois.
      if (!localOnly &&
          _isInternUser &&
          _scheduleShiftDay != null &&
          _scheduleShiftDay != _openShiftDayKey()) {
        unawaited(_refreshWorkSchedule());
      }
    } catch (e) {
      debugPrint('Erro records: $e');
    }
  }

  // Procura, alem do dia de hoje, um turno que ficou aberto em um dia anterior
  // (check_in sem check_out). Isso garante que a tela reconheca o turno mesmo
  // depois da virada do dia: o estagiario ganha a decisao (continuar ou fechar
  // as 19:30) em vez de travar com "Ja existe um turno aberto"; os demais
  // continuam "Em servico" e conseguem bater a saida.
  // A janela de 14 dias e a MESMA que o backend usa para decidir se ha turno
  // aberto. Com 10 dias aqui, um check_in preso entre 10 e 14 dias atras ficava
  // invisivel na tela (que so mostra hoje) enquanto o backend recusava a
  // entrada com "Ja existe um turno aberto". Recebe os registros ja lidos por
  // _loadTodayRecords em vez de consultar o Firestore de novo.
  Map<String, dynamic>? _carriedOpenShift(
      DateTime todayMidnight, List<dynamic> windowRecords) {
    final open = openShiftCheckIn(windowRecords);
    final openStart = DateTime.tryParse(open?['timestamp']?.toString() ?? '');
    return (openStart != null && openStart.isBefore(todayMidnight))
        ? open
        : null;
  }

  /// [retryBlocked]: toque em "Sincronizar" ou puxar para atualizar; reenvia
  /// tambem os pontos que o servidor ja recusou. Devolve false quando nao
  /// rodou (outra sincronizacao desta tela em andamento).
  Future<bool> _trySyncOfflineRecords(
      {bool showMessage = false, bool retryBlocked = false}) async {
    if (_isSyncingOffline) return false;
    _isSyncingOffline = true;

    try {
      final syncedCount =
          await _apiService.syncOfflineRecords(retryBlocked: retryBlocked);
      final pendingRecords = await _apiService.getCurrentUserOfflineRecords();

      if (mounted) {
        setState(() => _applyOfflineCounts(pendingRecords));
      }

      if (syncedCount > 0) {
        await _loadTodayRecords();
        if (mounted && showMessage) {
          _showSuccess('$syncedCount registro(s) offline sincronizado(s).');
        }
      }
    } catch (e) {
      debugPrint('Erro ao sincronizar pontos offline: $e');
    } finally {
      _isSyncingOffline = false;
    }
    return true;
  }

  /// Ha batidas na fila (nao recusadas) de ate [at] que nao saem agora?
  /// Tenta envia-las antes. A batida online do estagiario passava na frente
  /// da propria entrada guardada: o backend recusava a saida ("Nao existe
  /// turno aberto") e ela nao era salva nem guardada.
  Future<bool> _queuedPunchesBefore(DateTime at) async {
    final key = at.toIso8601String();
    // Sem id (formato antigo) o ponto nunca sai da fila, e nao segura nada.
    bool waitingBefore(Map<String, dynamic> record) =>
        (record['id']?.toString() ?? '').isNotEmpty &&
        !ApiService.isBlockedOfflineRecord(record) &&
        (record['timestamp']?.toString() ?? '').compareTo(key) <= 0;
    if (!(await _apiService.getCurrentUserOfflineRecords())
        .any(waitingBefore)) {
      return false;
    }
    await ApiService.waitForOfflineSync();
    await _trySyncOfflineRecords();
    return (await _apiService.getCurrentUserOfflineRecords())
        .any(waitingBefore);
  }

  /// Saidas recusadas da fila (sync_status blocked) do turno aberto: depois
  /// da entrada dele e antes da proxima entrada da fila. A mais antiga
  /// primeiro.
  Future<List<Map<String, dynamic>>> _parkedExitsOfOpenShift() async {
    final from = openShiftCheckIn(_todayRecords)?['timestamp']?.toString();
    if (from == null) return const [];
    final queued = await _apiService.getCurrentUserOfflineRecords();
    String timestampOf(Map<String, dynamic> record) =>
        record['timestamp']?.toString() ?? '';
    String? until;
    for (final record in queued) {
      final timestamp = timestampOf(record);
      if (record['record_type'] == 'check_in' &&
          timestamp.compareTo(from) > 0 &&
          (until == null || timestamp.compareTo(until) < 0)) {
        until = timestamp;
      }
    }
    return queued
        .where((record) =>
            record['record_type'] == 'check_out' &&
            ApiService.isBlockedOfflineRecord(record) &&
            timestampOf(record).compareTo(from) > 0 &&
            (until == null || timestampOf(record).compareTo(until) < 0))
        .toList()
      ..sort((a, b) => timestampOf(a).compareTo(timestampOf(b)));
  }

  /// A saida deste turno ja esta guardada no aparelho, recusada pelo servidor
  /// (ex.: esperava a liberacao da hora extra)? Reenvia antes de gravar outra:
  /// bater de novo pagava ate a nova batida, e a guardada, enviada depois, nao
  /// valia (vale a ultima saida). Devolve true quando a batida pedida nao
  /// deve seguir.
  Future<bool> _resolveParkedExit() async {
    final parked = await _parkedExitsOfOpenShift();
    if (parked.isEmpty) return false;
    final shiftStart = openShiftCheckIn(_todayRecords)?['timestamp']?.toString();
    final at = DateFormat('dd/MM HH:mm')
        .format(DateTime.parse(parked.first['timestamp'].toString()).toLocal());
    await ApiService.waitForOfflineSync();
    await _trySyncOfflineRecords(retryBlocked: true);
    await _loadTodayRecords();
    if (!mounted) return true;
    if (openShiftCheckIn(_todayRecords)?['timestamp']?.toString() !=
        shiftStart) {
      final parkedId = parked.first['id']?.toString();
      final sent = !(await _apiService.getCurrentUserOfflineRecords())
          .any((record) => record['id']?.toString() == parkedId);
      if (!mounted) return true;
      if (sent) {
        _showSuccess('A saída de $at, guardada no aparelho, foi enviada.');
      } else {
        _showError(
            'Este turno já foi encerrado. Confira o status e tente de novo.');
      }
      return true;
    }
    final still = await _parkedExitsOfOpenShift();
    if (still.isEmpty) return false;
    if (!mounted) return true;
    _showError('Sua saída de $at já está guardada no aparelho: '
        '${still.first['sync_error'] ?? 'recusada pelo servidor.'} '
        'Depois da liberação do gestor, toque em Sincronizar. Para bater '
        'outra saída, descarte a guardada.');
    return true;
  }

  void _updateStatus() {
    if (_todayRecords.isEmpty) {
      _currentStatus = "Aguardando entrada";
      _lastActionTime = "";
      return;
    }

    final last = _todayRecords.last;
    _lastActionTime = "desde ${_recordTimeLabel(last)}";

    // Sem turno aberto o status segue os botoes (_punchOptions): pausas
    // soltas nao sao "Em servico".
    if (!_hasOpenPoint) {
      final closed =
          _todayRecords.any((record) => record['record_type'] == 'check_out');
      _currentStatus = closed ? "Expediente encerrado" : "Aguardando entrada";
      if (!closed) _lastActionTime = "";
      return;
    }

    switch (last['record_type']) {
      case 'check_in':
        _currentStatus = "Em serviço";
        break;
      case 'break_start':
        _currentStatus = "Em pausa";
        break;
      case 'break_end':
        _currentStatus = "Em serviço (retorno)";
        break;
      case 'check_out':
        _currentStatus = "Expediente encerrado";
        break;
      default:
        _currentStatus = "Status atualizado";
    }
  }

  /// Posicao para a batida; null sem permissao ou sem sinal. Nunca lanca:
  /// pode ficar sem ninguem esperando (batida cancelada numa confirmacao).
  Future<Position?> _punchPosition() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return null;
      }
      try {
        return await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 5),
        );
      } catch (e) {
        // Sem sinal no prazo: a ultima posicao conhecida e melhor que
        // nenhuma (nao existe no web).
        debugPrint('Localizacao atual indisponivel: $e');
        return kIsWeb ? null : await Geolocator.getLastKnownPosition();
      }
    } catch (e) {
      debugPrint('Erro ao obter localização: $e');
      return null;
    }
  }

  Future<void> _registerPunch(
    String type, {
    DateTime? timestamp,
    String? notes,
    String? location,
  }) async {
    // Trava de reentrada: evita duplo-registro por toque duplo no botao.
    if (_punchInFlight) return;
    setState(() => _punchInFlight = true);
    // A batida vale a hora do toque, nao a de depois da conferencia abaixo e
    // da localizacao (ate ~25s com sinal ruim): a saida tocada 19:34:50 ia
    // como 19:35:10, depois do limite, e pedia liberacao de hora extra.
    final tappedAt = DateTime.now();
    // GPS comeca ja, junto com a conferencia abaixo e as confirmacoes: antes
    // so comecava depois delas e somava ate 5 s a cada batida (dentro de
    // predio o sinal costuma gastar o prazo inteiro).
    final positionFuture = _punchPosition();

    // Confere de novo antes de QUALQUER batida: a tela pode estar velha (app
    // aberto desde ontem, ponto batido em outro aparelho). Ex.: o celular
    // ainda mostra FINALIZAR depois da saida batida no PC, e um segundo
    // check_out somaria horas. Fora do estagiario o ponto vai direto para o
    // Firestore, sem as travas do backend; esta e a unica protecao.
    await _loadTodayRecords();
    if (!mounted) return;
    if (type == 'check_in') {
      final open = openShiftCheckIn(_todayRecords);
      if (open != null) {
        final since = DateTime.parse(open['timestamp'].toString()).toLocal();
        _showError('Você já tem um turno aberto desde '
            '${DateFormat('dd/MM \'às\' HH:mm').format(since)}. '
            'Registre a saída antes de iniciar outro.');
        setState(() => _punchInFlight = false);
        return;
      }
    }
    if (!_punchOptions().allows(type)) {
      _showError('A tela estava desatualizada. Confira o status e tente de novo.');
      setState(() => _punchInFlight = false);
      return;
    }
    if (type == 'check_out' && await _resolveParkedExit()) {
      if (mounted) setState(() => _punchInFlight = false);
      return;
    }
    if (type == 'check_in' &&
        _isInternUser &&
        !await _confirmNewStartRequest()) {
      if (mounted) setState(() => _punchInFlight = false);
      return;
    }
    if (!mounted) return;

    String? recordId;
    if (type == 'check_out' && _carriedOpenShiftStart != null) {
      final shiftStart = _carriedOpenShiftStart!;
      final checkInId = _carriedOpenShiftId ?? '';
      final choice = await _confirmCarriedShiftExit(shiftStart);
      if (!mounted) return;
      if (choice == null) {
        setState(() => _punchInFlight = false);
        return;
      }
      if (choice == _CarriedExit.forgot) {
        // Fecha o turno sem horas: a saida fica 1s depois da entrada e o
        // gestor lanca o horario real em Registros da equipe. Registrar
        // "agora" pagaria como trabalhada a noite inteira.
        timestamp = shiftStart.add(const Duration(seconds: 1));
        notes = 'Saida esquecida: o gestor precisa lancar o horario real';
        location = 'App (saida esquecida)';
        // Id fixo pela entrada: "Esqueci" em dois aparelhos, ou a fila
        // offline fechando o mesmo turno, gravam a mesma saida, nao duas.
        if (checkInId.isNotEmpty) recordId = 'forgot_$checkInId';
      }
    }

    if (type == 'check_in' && _closedShiftToday) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Novo Turno'),
          content: const Text(
              'Você já encerrou um turno hoje. Tem certeza que deseja iniciar um novo?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar',
                    style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: wineColor),
              child: const Text('Sim, Continuar',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirm != true) {
        setState(() => _punchInFlight = false);
        return;
      }
    }

    setState(() => _isLoading = true);

    try {
      // 1. Localizacao (pedida no toque, ver _punchPosition)
      final position = await positionFuture;

      // 2. Estagiarios usam validacao autoritativa do backend na entrada/saida.
      final attemptedAt = timestamp ?? tappedAt;
      Map<String, dynamic> result;
      if (_isInternUser && (type == 'check_in' || type == 'check_out')) {
        // Id gerado ANTES do envio: se a rede cair depois de o backend gravar
        // (resposta perdida), a fila reenvia com o mesmo id e o backend
        // devolve o ponto que ja existe em vez de duplicar ou recusar.
        final punchId = _apiService.newTimeRecordId();
        Future<Map<String, dynamic>> queue(DateTime at) =>
            _apiService.queueTimeRecordOffline(
              recordType: type,
              timestamp: at.toIso8601String(),
              notes: notes,
              location: location,
              latitude: position?.latitude,
              longitude: position?.longitude,
              id: punchId,
            );
        // Batidas anteriores ainda na fila (a entrada das 13:30 feita sem
        // internet): esta vai atras delas, na ordem, em vez de chegar antes
        // ao backend e ser recusada.
        if (await _queuedPunchesBefore(attemptedAt)) {
          await queue(attemptedAt);
          await _loadTodayRecords();
          _showSuccess('Registro salvo no aparelho: ele será enviado depois '
              'dos pontos que ainda aguardam sincronização.');
          unawaited(_trySyncOfflineRecords());
          return;
        }
        Future<Map<String, dynamic>> punchOrQueue(DateTime at) async {
          try {
            return await _apiService.createScheduleControlledPunch(
              recordType: type,
              timestamp: at.toIso8601String(),
              notes: notes,
              location: location,
              latitude: position?.latitude,
              longitude: position?.longitude,
              clientRecordId: punchId,
            );
          } catch (e) {
            // Sem rede o backend nao responde. Em vez de perder a batida,
            // guarda na fila: a sincronizacao reenvia pelo mesmo endpoint
            // (com as regras de horario) quando a internet voltar.
            if (!ApiService.isNetworkFailure(e)) rethrow;
            debugPrint('Backend inacessivel, guardando ponto na fila: $e');
            return queue(at);
          }
        }

        result = await punchOrQueue(attemptedAt);
        if (result['status'] == 'approval_required') {
          final requestType =
              result['request_type']?.toString() ?? 'start_exception';
          final retryCheckOut =
              type == 'check_out' && requestType == 'overtime';
          final alreadyApproved = await _offerScheduleApproval(
            requestType,
            attemptedAt,
            position,
            reason: result['reason']?.toString(),
            retryingPunch: retryCheckOut,
          );
          if (!alreadyApproved || !retryCheckOut) return;
          // O gestor liberou entre a batida e o pedido: tenta a saida de
          // novo, uma vez, agora com a liberacao valendo.
          result = await punchOrQueue(DateTime.now());
          if (result['status'] == 'approval_required') {
            _showError('A liberação ainda não vale para esta saída. '
                'Atualize a tela e tente de novo.');
            return;
          }
        }
      } else {
        result = await _apiService.createTimeRecord(
          recordType: type,
          timestamp: (timestamp ?? tappedAt).toIso8601String(),
          notes: notes,
          location: location,
          latitude: position?.latitude,
          longitude: position?.longitude,
          recordId: recordId,
        );
      }

      await _loadTodayRecords();
      if (result['offline'] == true) {
        _showSuccess(
            'Sem internet. Registro salvo no aparelho para sincronizar depois.');
      } else {
        _showSuccess('Registro de ${_getRecordLabel(type)} salvo com sucesso!');
        unawaited(_trySyncOfflineRecords());
      }
    } catch (e) {
      _showError('Erro ao registrar: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _punchInFlight = false;
        });
      }
    }
  }

  /// Ja ha pedido de entrada de hoje aguardando o gestor? Liberado, ele abre
  /// o turno na hora do pedido. Um pedido novo, mais de 15 min depois,
  /// substitui o anterior e a entrada passa a ser a hora dele: tocar de novo
  /// enquanto esperava deixava sem pagar o tempo ate o segundo toque. So
  /// segue (devolve true) sem pedido pendente ou com a confirmacao de que e
  /// uma nova chegada.
  Future<bool> _confirmNewStartRequest() async {
    if (_pendingStartRequestAt == null) return true;
    await _refreshWorkSchedule(refreshRecords: true);
    if (!mounted) return false;
    if (_hasOpenPoint) {
      _showSuccess('Sua entrada já foi liberada pelo gestor.');
      return false;
    }
    final requestedAt = _pendingStartRequestAt;
    if (requestedAt == null) return true;
    final hour = DateFormat('HH:mm').format(requestedAt);
    final again = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Entrada aguardando liberação'),
        content: Text(
            'Você já pediu a liberação da entrada às $hour e o pedido aguarda '
            'um gestor. Liberado, a entrada fica registrada às $hour.\n\n'
            'Só peça de novo se você saiu e está chegando agora: o novo '
            'pedido substitui o anterior.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Aguardar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: wineColor),
            child: const Text('Pedir de novo',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return again == true;
  }

  /// Saida de um turno que comecou em outro dia. Turno da noite e saida
  /// esquecida tem a mesma cara na tela; so quem bateu sabe qual foi, entao o
  /// app pergunta. Acima de [maxShiftSpan] so resta fechar sem horas.
  /// Estagiario nao tem a opcao "esqueci": o backend recusa saida retroativa,
  /// e ele ja tem "Fechar no horario programado".
  Future<_CarriedExit?> _confirmCarriedShiftExit(DateTime shiftStart) {
    final now = DateTime.now();
    final tooLong = now.difference(shiftStart) > maxShiftSpan;
    final allowForgot = !_isInternUser;
    final format = DateFormat('dd/MM/yyyy \'às\' HH:mm');
    final started = 'Seu turno começou em ${format.format(shiftStart)}';
    final String message;
    if (!allowForgot) {
      message = '$started e a saída será registrada agora, '
          '${format.format(now)}.';
    } else if (tooLong) {
      message = '$started e está aberto há mais de ${maxShiftSpan.inHours} '
          'horas. O turno será fechado sem contar horas: avise o gestor para '
          'lançar o horário real em que você saiu.';
    } else {
      message = '$started.\n\nSe você trabalhou até agora, registre a saída '
          '(${format.format(now)}). Se esqueceu de bater a saída, escolha '
          '"Esqueci": o turno fecha sem horas e o gestor lança o horário real.';
    }
    return showDialog<_CarriedExit>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finalizar turno aberto'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar',
                  style: TextStyle(color: Colors.grey))),
          if (allowForgot)
            TextButton(
              onPressed: () => Navigator.pop(context, _CarriedExit.forgot),
              child: Text(tooLong ? 'Fechar sem horas' : 'Esqueci',
                  style: const TextStyle(color: wineColor)),
            ),
          if (!allowForgot || !tooLong)
            ElevatedButton(
              onPressed: () => Navigator.pop(context, _CarriedExit.now),
              style: ElevatedButton.styleFrom(backgroundColor: wineColor),
              child: const Text('Registrar saída agora',
                  style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
    );
  }

  /// Pede liberacao ao gestor. Devolve true quando ela ja estava aprovada
  /// (resposta "existing" com status approved): nada novo foi pedido. Com
  /// [retryingPunch], quem chamou tenta a batida de novo e da a mensagem.
  Future<bool> _offerScheduleApproval(
    String requestType,
    DateTime attemptedAt,
    Position? position, {
    String? reason,
    bool retryingPunch = false,
  }) async {
    if (!mounted) return false;
    final isStart = requestType == 'start_exception';
    final formKey = GlobalKey<FormState>();
    final observationController = TextEditingController();
    final observation = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isStart ? 'Entrada fora do horario' : 'Horario encerrado'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isStart
                      ? reason == 'non_working_day'
                          ? 'Estagiarios trabalham de segunda a sexta. Para iniciar no fim de semana, peca liberacao e explique o que voce vai fazer.'
                          : 'Seu horario permitido para iniciar e de ${_effectiveSchedule['start_allowed_from']} ate ${_effectiveSchedule['start_allowed_until']}. Para pedir liberacao, explique o motivo.'
                      : 'Para continuar depois de ${_effectiveSchedule['shift_end']}, explique ao gestor o que voce esta fazendo.',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: observationController,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 5,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Observacao para o gestor',
                    hintText:
                        'Ex.: Estou finalizando o relatorio do projeto...',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Explique o motivo da solicitacao.';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('SAIR'),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(context, observationController.text.trim());
            },
            style: ElevatedButton.styleFrom(backgroundColor: wineColor),
            child: const Text('SOLICITAR LIBERACAO',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    observationController.dispose();
    if (observation == null) return false;

    try {
      final response = await _apiService.createScheduleApprovalRequest(
        requestType: requestType,
        attemptedAt: attemptedAt.toIso8601String(),
        shiftStartAt: _currentShiftStartDate()?.toIso8601String(),
        location: 'App',
        notes: observation,
        latitude: position?.latitude,
        longitude: position?.longitude,
      );
      await _refreshWorkSchedule();
      final existing = response['status'] == 'existing';
      final request = response['request'];
      if (existing && request is Map && request['status'] == 'approved') {
        if (!retryingPunch) {
          // Entrada aprovada: o backend grava o ponto na aprovacao, so falta
          // a tela mostrar.
          if (isStart) await _loadTodayRecords();
          if (!mounted) return true;
          _showSuccess(isStart
              ? 'Sua entrada já foi liberada pelo gestor.'
              : 'A continuação do expediente já foi liberada pelo gestor.');
        }
        return true;
      }
      if (!mounted) return false;
      _showSuccess(existing
          ? 'Sua solicitacao ja esta aguardando um gestor.'
          : 'Solicitacao enviada para os gestores.');
    } catch (e) {
      if (mounted) _showError('Nao foi possivel solicitar a liberacao: $e');
    }
    return false;
  }

  DateTime? _currentShiftStartDate() {
    final lastCheckInIndex = _todayRecords.lastIndexWhere(
      (record) => record['record_type'] == 'check_in',
    );
    if (lastCheckInIndex >= 0) {
      return DateTime.parse(_todayRecords[lastCheckInIndex]['timestamp']).toLocal();
    }
    // Turno que comecou em um dia anterior e nunca foi fechado.
    return _carriedOpenShiftStart;
  }

  Future<void> _finishInternShiftAtScheduledEnd() async {
    if (_punchInFlight) return;
    setState(() => _punchInFlight = true);
    try {
      // Mesma conferencia das outras batidas: a saida pode ja ter sido
      // batida em outro aparelho.
      await _loadTodayRecords();
      if (!mounted) return;
      if (!_hasOpenPoint) {
        _showError(
            'A tela estava desatualizada. Confira o status e tente de novo.');
        return;
      }
      await _closeInternShiftAtScheduledEnd();
    } finally {
      if (mounted) setState(() => _punchInFlight = false);
    }
  }

  Future<void> _closeInternShiftAtScheduledEnd() async {
    final shiftStart = _currentShiftStartDate();
    if (shiftStart == null) {
      _showError('Nao encontrei a entrada deste turno para fechar no horario.');
      return;
    }

    final closeAt = _dateAtConfiguredTime(shiftStart, 'shift_end');
    // Mesma conferencia do backend; sem internet a saida iria para a fila e
    // ficaria parada la ("Nao existe turno aberto" as 19:30).
    if (closeAt.isBefore(shiftStart)) {
      _showError('A entrada foi depois de ${_effectiveSchedule['shift_end']}. '
          'Use FINALIZAR EXPEDIENTE no horário real.');
      return;
    }
    // Saida no futuro fecharia o turno antes da hora e pagaria minutos nao
    // trabalhados (o backend tambem recusa).
    if (closeAt.isAfter(DateTime.now())) {
      _showError('Ainda não deu ${_effectiveSchedule['shift_end']}. '
          'Para sair agora, use FINALIZAR EXPEDIENTE.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Fechar ponto as ${_effectiveSchedule['shift_end']}'),
        content: Text(
          'O expediente sera finalizado em ${DateFormat('dd/MM/yyyy HH:mm:ss').format(closeAt)}, no mesmo dia em que o turno comecou.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: wineColor),
            child:
                const Text('Confirmar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() => _isLoading = true);
    try {
      const notes = 'Fechamento no horario configurado do estagiario';
      const location = 'App (horario programado)';
      // Lidas antes de gravar: depois o turno ja nao aparece aberto.
      final replaced = await _parkedExitsOfOpenShift();
      // Id antes do envio, como nas outras batidas: com a resposta perdida
      // depois de o backend gravar, a copia da fila devolve o ponto gravado
      // em vez de ser recusada ("Nao existe turno aberto") e segurar a fila.
      final closeId = _apiService.newTimeRecordId();
      Future<void> queue() => _apiService.queueTimeRecordOffline(
            recordType: 'check_out',
            timestamp: closeAt.toIso8601String(),
            notes: notes,
            location: location,
            id: closeId,
            closeAtScheduledEnd: true,
          );
      // Sem internet a saida no horario programado vai para a fila e a
      // sincronizacao a reenvia como fechamento. Com batidas anteriores
      // ainda na fila (a entrada feita sem internet), vai atras delas.
      var queued = await _queuedPunchesBefore(closeAt);
      if (queued) {
        await queue();
      } else {
        try {
          await _apiService.createScheduleControlledPunch(
            recordType: 'check_out',
            timestamp: closeAt.toIso8601String(),
            notes: notes,
            location: location,
            closeAtScheduledEnd: true,
            clientRecordId: closeId,
          );
        } catch (e) {
          if (!ApiService.isNetworkFailure(e)) rethrow;
          await queue();
          queued = true;
        }
      }
      // A saida deste turno parada na fila (esperava a liberacao da hora
      // extra) foi substituida por este fechamento. Mantida, ela seria
      // recusada ("Nao existe turno aberto") e seguraria os pontos seguintes.
      if (replaced.isNotEmpty) {
        await _apiService.discardCurrentUserOfflineRecords(
            {for (final record in replaced) record['id'].toString()});
        unawaited(_trySyncOfflineRecords());
      }
      await _loadTodayRecords();
      await _refreshWorkSchedule();
      final replacedNote = replaced.isEmpty
          ? ''
          : ' A saída guardada de ${DateFormat('dd/MM HH:mm').format(DateTime.parse(replaced.first['timestamp'].toString()).toLocal())} foi descartada.';
      _showSuccess(queued
          ? 'Saída das ${_effectiveSchedule['shift_end']} salva no aparelho '
              'para sincronizar depois.$replacedNote'
          : 'Ponto fechado em ${_effectiveSchedule['shift_end']}.'
              '$replacedNote');
    } catch (e) {
      _showError('Erro ao fechar o ponto: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: wineColor));
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle, color: Colors.white),
        const SizedBox(width: 8),
        Text(msg)
      ]),
      backgroundColor: Colors.blue.shade800,
      behavior: SnackBarBehavior.floating,
    ));
  }

  String _getRecordLabel(String type) {
    switch (type) {
      case 'check_in':
        return 'Entrada';
      case 'check_out':
        return 'Saída';
      case 'break_start':
        return 'Pausa 1 (Início)';
      case 'break_end':
        return 'Pausa 1 (Retorno)';
      case 'entry_3':
        return 'Pausa 2 (Início)';
      case 'exit_3':
        return 'Pausa 2 (Retorno)';
      default:
        return type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          const UserNotificationBell(),
          IconButton(
            icon: const Icon(Icons.chat_outlined, color: wineColor),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const UserChatListScreen()),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: _isLoading && _todayRecords.isEmpty
          ? const StartupLoading(from: 94, to: 99)
          : _isOvertimeDecisionRequired
              ? _buildOvertimeDecisionScreen(theme)
              : RefreshIndicator(
                  onRefresh: () async {
                    await _trySyncOfflineRecords(
                        showMessage: true, retryBlocked: true);
                    await _loadTodayRecords();
                  },
                  color: wineColor,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 80, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildClockCard(theme, isDark),
                        const SizedBox(height: 16),
                        if (_pendingOfflineRecordsCount > 0) ...[
                          _buildOfflineSyncBanner(theme),
                          const SizedBox(height: 12),
                        ],
                        if (_carriedOpenShiftStart != null) ...[
                          _buildCarriedShiftBanner(theme),
                          const SizedBox(height: 12),
                        ],
                        if (_isInternUser &&
                            !_hasOpenPoint &&
                            _pendingStartRequestAt != null) ...[
                          _buildStartRequestBanner(theme),
                          const SizedBox(height: 12),
                        ],
                        _buildStatusCard(theme, isDark),
                        const SizedBox(height: 24),
                        _buildActionButtons(),
                        const SizedBox(height: 32),
                        _buildHistoryList(theme, isDark),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildOvertimeDecisionScreen(ThemeData theme) {
    final pending = _overtimeRequestStatus == 'pending';
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.grey.shade400,
      child: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            // Como na tela de ponto: a saida parada na fila (ex.: esperava a
            // liberacao que o gestor ja deu) so sai com o reenvio.
            await _trySyncOfflineRecords(showMessage: true, retryBlocked: true);
            await _refreshWorkSchedule(refreshRecords: true);
          },
          color: wineColor,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 70, 20, 24),
            children: [
              if (_pendingOfflineRecordsCount > 0) ...[
                _buildOfflineSyncBanner(theme),
                const SizedBox(height: 12),
              ],
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Icon(Icons.schedule_outlined,
                          size: 58, color: wineColor),
                      const SizedBox(height: 16),
                      const Text(
                        'HORARIO PROGRAMADO ENCERRADO',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _carriedOpenShiftStart != null
                            ? 'Voce iniciou um turno em ${DateFormat('dd/MM/yyyy \'as\' HH:mm').format(_carriedOpenShiftStart!)} e nao registrou a saida. O dia ja virou: escolha continuar (com liberacao do gestor) ou fechar o ponto as ${_effectiveSchedule['shift_end']} do dia em que comecou.'
                            : 'Seu expediente terminou as ${_effectiveSchedule['shift_end']}. Para continuar trabalhando, a gestao precisa liberar o horario.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: theme.textTheme.bodyMedium?.color,
                            height: 1.4),
                      ),
                      if (pending) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.hourglass_top, color: Colors.orange),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Solicitacao enviada. Aguardando um gestor.',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: pending
                              ? null
                              : () => _offerScheduleApproval(
                                    'overtime',
                                    DateTime.now(),
                                    null,
                                  ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: wineColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.send_outlined),
                          label: Text(pending
                              ? 'AGUARDANDO LIBERACAO'
                              : 'CONTINUAR E NOTIFICAR GESTOR'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _finishInternShiftAtScheduledEnd,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: wineColor,
                            side: const BorderSide(color: wineColor),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.logout),
                          label: Text(
                              'FECHAR PONTO AS ${_effectiveSchedule['shift_end']}'),
                        ),
                      ),
                      // Sem internet o pedido de liberacao nao sai e a
                      // liberacao ja dada pode nao ter chegado: a saida
                      // agora vai para a fila, e o servidor confere a
                      // liberacao quando ela sincronizar (sem ela, a saida
                      // fica parada com o motivo no aviso).
                      if (_workScheduleOffline) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Sem internet. Se o gestor ja liberou a hora extra, registre a saida agora: ela fica no aparelho e o servidor confere a liberacao quando a internet voltar.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: theme.textTheme.bodyMedium?.color,
                              fontSize: 12,
                              height: 1.4),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _punchInFlight
                                ? null
                                : () => _registerPunch('check_out'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: wineColor,
                              side: const BorderSide(color: wineColor),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                            ),
                            icon: const Icon(Icons.cloud_off),
                            label: const Text('FINALIZAR EXPEDIENTE AGORA'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Com batidas recusadas na fila, o descarte padrao leva so elas: as que
  /// aguardam internet sao boas (a entrada de hoje, enquanto a saida de ontem
  /// foi recusada) e "descartar tudo" fica como opcao separada.
  Future<void> _confirmDiscardOffline() async {
    final blocked = _blockedOfflineRecordsCount;
    final waiting = _pendingOfflineRecordsCount - blocked;
    // Saida recusada do turno que segue aberto: descartada com pontos
    // esperando por ela, o turno continua aberto no servidor e os seguintes
    // sao recusados um a um ("Ja existe um turno aberto"). O caminho e fechar
    // o turno (FECHAR PONTO, que substitui a saida guardada) ou a liberacao.
    final parked = blocked > 0
        ? await _parkedExitsOfOpenShift()
        : const <Map<String, dynamic>>[];
    if (!mounted) return;
    final canClose = parked.isNotEmpty && _isInternUser;
    final shiftEnd = _effectiveSchedule['shift_end'];
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar pendências?'),
        content: Text(blocked > 0
            ? 'Isso apaga o(s) $blocked registro(s) que o servidor recusou.'
                '${waiting > 0 ? ' Os $waiting que aguardam internet continuam '
                    'no aparelho e serão enviados quando ela voltar.' : ''}'
                '${parked.isNotEmpty && waiting > 0 ? '\n\nAtenção: a saída '
                    'recusada é a do turno que continua aberto. Sem ela, os '
                    'registros que aguardam serão recusados. Feche o turno '
                    '${canClose ? 'às $shiftEnd ' : ''}ou peça a liberação ao '
                    'gestor antes de descartar.' : ''}'
            : 'Isso apaga os $_pendingOfflineRecordsCount registro(s) que ainda '
                'não sincronizaram. Use apenas se eles estiverem presos ou forem '
                'inválidos — os pontos descartados não serão enviados.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          if (canClose)
            TextButton(
              onPressed: () => Navigator.pop(context, 'close'),
              child: Text('Fechar às $shiftEnd',
                  style: const TextStyle(color: wineColor)),
            ),
          if (blocked > 0 && waiting > 0)
            TextButton(
              onPressed: () => Navigator.pop(context, 'all'),
              child: const Text('Descartar tudo',
                  style: TextStyle(color: Colors.red)),
            ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(context, blocked > 0 ? 'blocked' : 'all'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: Text(blocked > 0 ? 'Descartar recusados' : 'Descartar',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'close') {
      await _finishInternShiftAtScheduledEnd();
      return;
    }
    final onlyBlocked = choice == 'blocked';
    if (onlyBlocked) {
      await _apiService.clearCurrentUserBlockedOfflineRecords();
    } else {
      await _apiService.clearCurrentUserOfflineRecords();
    }
    // A sincronizacao que ja rodava confere a fila antes de cada ponto e para
    // nos descartados; espera ela acabar para a lista mostrar o que ficou.
    await ApiService.waitForOfflineSync();
    await _loadTodayRecords();
    if (!mounted) return;
    _showSuccess(onlyBlocked
        ? 'Registros recusados descartados.'
        : 'Pendências offline descartadas.');
    // A recusada segurava as seguintes na fila; agora elas podem sair.
    if (onlyBlocked) unawaited(_trySyncOfflineRecords(showMessage: true));
  }

  Widget _buildOfflineSyncBanner(ThemeData theme) {
    final waiting = _pendingOfflineRecordsCount - _blockedOfflineRecordsCount;
    // Recusadas so por falta da liberacao: com ela, a mesma batida passa
    // (sozinha ou no Sincronizar). Bater de novo pagava ate a nova batida.
    final awaitingApproval = _awaitingApprovalOfflineRecordsCount;
    final otherBlocked = _blockedOfflineRecordsCount - awaitingApproval;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              [
                if (waiting > 0)
                  '$waiting registro(s) aguardando internet para sincronizar.',
                if (awaitingApproval > 0)
                  '$awaitingApproval registro(s) aguardando a liberação do '
                      'gestor. Quando ele liberar, o envio é automático (ou '
                      'toque em Sincronizar). Não bata de novo.',
                if (otherBlocked > 0)
                  '$otherBlocked registro(s) recusado(s) pelo '
                      'servidor: ${_blockedOfflineReason ?? ''} '
                      '${waiting > 0 ? 'Os que aguardam esperam por ele. ' : ''}'
                      'Bata de novo ou avise o gestor; depois descarte os '
                      'recusados.',
              ].join('\n'),
              style: TextStyle(
                color: theme.textTheme.bodyMedium?.color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: _isSyncingOffline
                ? null
                : () => _trySyncOfflineRecords(
                    showMessage: true, retryBlocked: true),
            child: const Text('Sincronizar'),
          ),
          IconButton(
            onPressed: _isSyncingOffline ? null : _confirmDiscardOffline,
            icon: const Icon(Icons.delete_outline, size: 20),
            color: Colors.orange,
            tooltip: 'Descartar pendências',
          ),
        ],
      ),
    );
  }

  /// Pedido de entrada fora do horario aguardando o gestor: sem o aviso a
  /// tela seguia com REGISTRAR ENTRADA, e o novo toque substituia o pedido.
  Widget _buildStartRequestBanner(ThemeData theme) {
    final at = DateFormat('HH:mm').format(_pendingStartRequestAt!);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.hourglass_top, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Entrada aguardando liberação do gestor (pedido às $at). '
              'Liberada, ela fica registrada nesse horário.',
              style: TextStyle(
                color: theme.textTheme.bodyMedium?.color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarriedShiftBanner(ThemeData theme) {
    final since =
        DateFormat('dd/MM \'às\' HH:mm').format(_carriedOpenShiftStart!);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: wineColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: wineColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, color: wineColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Turno aberto desde $since. Registre a saída antes de iniciar outro turno.',
              style: TextStyle(
                color: theme.textTheme.bodyMedium?.color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClockCard(ThemeData theme, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: theme.primaryColor, width: 4)),
      ),
      child: Column(
        children: [
          Text(_currentDate,
              style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.1)),
          const SizedBox(height: 8),
          Text(_currentTime,
              style: TextStyle(
                  color: theme.primaryColor,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Roboto',
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 12),
          _buildUserTag(theme, isDark),
        ],
      ),
    );
  }

  Widget _buildUserTag(ThemeData theme, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
              radius: 8,
              backgroundColor: theme.primaryColor.withOpacity(0.8),
              child: Text(_displayUserName[0].toUpperCase(),
                  style: const TextStyle(fontSize: 9, color: Colors.white))),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _displayUserName,
              maxLines: 2,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: theme.textTheme.bodyMedium?.color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme, bool isDark) {
    bool isWorking = _currentStatus.contains("serviço") ||
        _currentStatus.contains("retorno");
    Color statusColor = isWorking
        ? Colors.green
        : (_currentStatus.contains("pausa") ? Colors.orange : wineColor);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      color: statusColor, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Text(_currentStatus,
                  style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          Text(_lastActionTime,
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }

  /// Batidas liberadas para os pontos da tela. A mesma regra desenha os
  /// botoes e confere a batida de novo, ja com os pontos recarregados, antes
  /// de gravar (tela velha).
  _PunchOptions _punchOptions() {
    if (!_hasOpenPoint || _todayRecords.isEmpty) {
      return const _PunchOptions('check_in', 'REGISTRAR ENTRADA', false);
    }
    final last = _todayRecords.last['record_type'];

    int lastCheckInIdx =
        _todayRecords.lastIndexWhere((r) => r['record_type'] == 'check_in');
    // Sem entrada na lista (ponto solto, ex.: retorno de pausa fechado
    // depois da meia-noite) o sublist(-1) derrubava a tela.
    var currentSessionRecords =
        _todayRecords.sublist(lastCheckInIdx < 0 ? 0 : lastCheckInIdx);

    int breakStarts = currentSessionRecords
        .where((r) =>
            r['record_type'] == 'break_start' || r['record_type'] == 'entry_3')
        .length;
    if ((last == 'check_in' || last == 'break_end') && breakStarts < 2) {
      return _PunchOptions(breakStarts == 0 ? 'break_start' : 'entry_3',
          'INICIAR PAUSA ${breakStarts + 1}', true);
    }
    if (last == 'break_start' || last == 'entry_3') {
      return _PunchOptions(last == 'break_start' ? 'break_end' : 'exit_3',
          'RETORNAR DA PAUSA', false);
    }
    return const _PunchOptions(null, 'REGISTRAR ENTRADA', true);
  }

  /// Ja houve turno encerrado HOJE, pelo dia de trabalho? A saida 07:00 do
  /// turno que comecou ontem 19:30 e de ontem: pela data do ponto, quem
  /// trabalha a noite ouvia "Voce ja encerrou um turno hoje" toda noite.
  bool get _closedShiftToday {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final day = groupRecordsByWorkDay(_windowRecords)[today] ?? const [];
    return day.any((record) => record['record_type'] == 'check_out');
  }

  Widget _buildActionButtons() {
    final options = _punchOptions();
    final breakAction = options.mainAction;

    return Column(
      children: [
        if (breakAction != null)
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed:
                  _punchInFlight ? null : () => _registerPunch(breakAction),
              style: ElevatedButton.styleFrom(
                  backgroundColor: wineColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: Text(options.mainLabel,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ),
        if (options.canExit) ...[
          const SizedBox(height: 10),
          _buildFinishShiftButton(),
        ]
      ],
    );
  }

  Widget _buildFinishShiftButton() {
    final buttonStyle = OutlinedButton.styleFrom(
      side: const BorderSide(color: wineColor, width: 1.5),
      foregroundColor: wineColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

    if (!_isInternUser) {
      return SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton(
          onPressed:
              _punchInFlight ? null : () => _registerPunch('check_out'),
          style: buttonStyle,
          child: const Text(
            'FINALIZAR EXPEDIENTE',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }

    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed:
              _punchInFlight ? null : () => _registerPunch('check_out'),
              style: buttonStyle.copyWith(
                shape: WidgetStateProperty.all(
                  const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.horizontal(left: Radius.circular(12)),
                  ),
                ),
              ),
              child: const Text(
                'FINALIZAR EXPEDIENTE',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(width: 2),
          PopupMenuButton<String>(
            tooltip: 'Mais opcoes',
            onSelected: (value) {
              if (value == 'intern_1930') {
                _finishInternShiftAtScheduledEnd();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'intern_1930',
                child: Text('Fechar no horario programado'),
              ),
            ],
            child: Container(
              width: 48,
              height: 44,
              decoration: BoxDecoration(
                border: Border.all(color: wineColor, width: 1.5),
                borderRadius:
                    const BorderRadius.horizontal(right: Radius.circular(12)),
              ),
              child: const Icon(Icons.keyboard_arrow_down, color: wineColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryList(ThemeData theme, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            _carriedOpenShiftStart != null
                ? 'REGISTROS DO TURNO'
                : 'REGISTROS DE HOJE',
            style: const TextStyle(
                color: Colors.grey,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1)),
        const SizedBox(height: 12),
        if (_todayRecords.isEmpty)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Nenhum registro encontrado hoje',
                      style: TextStyle(color: Colors.grey, fontSize: 12)))),
        ..._todayRecords.reversed
            .map((r) => _buildHistoryItem(r, theme, isDark))
            .toList(),
      ],
    );
  }

  /// Hora do ponto, com a data na frente quando ele e de outro dia (turno
  /// aberto que atravessou a meia-noite).
  String _recordTimeLabel(dynamic record) {
    final at = DateTime.parse(record['timestamp']).toLocal();
    final now = DateTime.now();
    final isToday =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return DateFormat(isToday ? 'HH:mm:ss' : 'dd/MM HH:mm').format(at);
  }

  Widget _buildHistoryItem(dynamic record, ThemeData theme, bool isDark) {
    final time = _recordTimeLabel(record);
    final type = record['record_type'];
    final isOffline = record['offline'] == true;

    IconData icon;
    Color iconColor;
    switch (type) {
      case 'check_in':
        icon = Icons.login;
        iconColor = Colors.green;
        break;
      case 'break_start':
        icon = Icons.coffee;
        iconColor = Colors.orange;
        break;
      case 'break_end':
        icon = Icons.directions_run;
        iconColor = Colors.blue;
        break;
      case 'check_out':
        icon = Icons.logout;
        iconColor = wineColor;
        break;
      default:
        icon = Icons.access_time;
        iconColor = Colors.grey;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      decoration: BoxDecoration(
        color: theme.cardColor.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color:
                      isDark ? Colors.black26 : Colors.black.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 12),
              Text(_getRecordLabel(type),
                  style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color,
                      fontSize: 14,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isOffline) ...[
                const Icon(Icons.sync_problem, color: Colors.orange, size: 16),
                const SizedBox(width: 6),
              ],
              Text(time,
                  style: TextStyle(
                      color: theme.textTheme.bodyMedium?.color,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Roboto',
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ],
      ),
    );
  }
}
