import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';
import '../services/update_service.dart';
import '../utils/daily_entries.dart';
import '../widgets/startup_loading.dart';
import '../widgets/user_notification_bell.dart';
import 'user_chat_list_screen.dart';
import '../widgets/content_width.dart';

/// Tela de ponto de quem esta no modo diaria (users.daily_mode): no lugar de
/// entrada, pausas e saida, um botao que marca a diaria do dia (uma por dia)
/// e as diarias do periodo da folha (29 a 28).
class DailyModeScreen extends StatefulWidget {
  const DailyModeScreen({super.key});

  @override
  State<DailyModeScreen> createState() => _DailyModeScreenState();
}

class _DailyModeScreenState extends State<DailyModeScreen>
    with WidgetsBindingObserver {
  static const Color wineColor = Color(0xFF8B0000);

  final _apiService = ApiService();
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  DateTime _now = DateTime.now();
  String _userName = '';
  bool _isLoading = true;
  bool _adding = false;
  // Diarias do periodo atual, com as guardadas no aparelho ('pending').
  List<Map<String, dynamic>> _entries = [];
  // Dia (yyyy-MM-dd) das diarias carregadas: virando o dia com a tela
  // aberta, recarrega e o botao volta a valer.
  String? _loadedDay;
  DateTime? _lastServerLoad;
  DateTime? _lastSyncAttempt;

  // A atualizacao automatica nao recarrega com a diaria sendo registrada.
  bool _busyCheck() => _adding;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    UpdateService.instance.addBusyCheck(_busyCheck);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) {
        unawaited(_syncPending(showMessage: true));
      }
    });
    _loadInitialData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UpdateService.instance.removeBusyCheck(_busyCheck);
    _timer?.cancel();
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Voltando do segundo plano: a diaria pode ter sido marcada em outro
    // aparelho, ou o dia pode ter virado.
    final last = _lastServerLoad;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 2)) {
      return;
    }
    unawaited(_refresh());
  }

  void _tick() {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() => _now = now);
    if (_loadedDay != null && _loadedDay != dailyDayKey(now)) {
      _loadedDay = dailyDayKey(now);
      unawaited(_load());
    }
    // Diaria guardada sem internet: tenta enviar a cada minuto.
    if (_entries.any((entry) => entry['pending'] == true) &&
        (_lastSyncAttempt == null ||
            now.difference(_lastSyncAttempt!) >= const Duration(minutes: 1))) {
      unawaited(_syncPending(showMessage: true));
    }
  }

  Future<void> _loadInitialData() async {
    try {
      final user = await _apiService.getCachedCurrentUser();
      _userName = (user?['name'] ?? user?['email'] ?? '').toString().trim();
      // Copia local primeiro: a tela aparece na hora, com ou sem internet.
      await _load(localOnly: true);
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('Copia local das diarias indisponivel: $e');
    }
    await _refresh();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _refresh() async {
    await _syncPending(showMessage: true);
    await _load();
  }

  Future<void> _load({bool localOnly = false}) async {
    final now = DateTime.now();
    final period = dailyPeriodFor(now);
    try {
      final entries = await _apiService.getMyDailyEntries(
          start: period.start, end: period.end, localOnly: localOnly);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loadedDay = dailyDayKey(now);
      });
      if (!localOnly) _lastServerLoad = now;
    } catch (e) {
      debugPrint('Erro ao carregar diarias: $e');
      if (mounted && !localOnly) _showError('Erro ao carregar as diárias: $e');
    }
  }

  /// Envia as diarias guardadas no aparelho e avisa das recusadas.
  Future<void> _syncPending({bool showMessage = false}) async {
    _lastSyncAttempt = DateTime.now();
    final before = (await _apiService.getPendingDailyEntries()).length;
    if (before == 0) return;
    try {
      final rejected = await _apiService.syncPendingDailyEntries();
      final after = (await _apiService.getPendingDailyEntries()).length;
      if (after == before) return;
      await _load();
      if (!mounted || !showMessage) return;
      if (rejected.isNotEmpty) {
        final day = DateFormat('dd/MM')
            .format(DateTime.parse(rejected.first['date'].toString()));
        _showError('A diária de $day, guardada no aparelho, não foi aceita: '
            '${rejected.first['sync_error']} Avise o gestor.');
      } else {
        _showSuccess('Diária guardada no aparelho enviada.');
      }
    } catch (e) {
      debugPrint('Erro ao enviar diarias guardadas: $e');
    }
  }

  Map<String, dynamic>? get _todayEntry => dailyEntryOn(_entries, _now);

  Future<void> _addDailyEntry() async {
    if (_adding || _todayEntry != null) return;
    final today = DateTime.now();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Adicionar diária'),
        content: Text('Registrar a diária de hoje, '
            '${DateFormat("EEEE, dd/MM/yyyy", 'pt_BR').format(today)}?\n\n'
            'Só dá para registrar uma diária por dia.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: wineColor),
            child:
                const Text('Registrar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _adding = true);
    try {
      final entry = await _apiService.addDailyEntry();
      final pending = entry['status'] == 'pending';
      await _load(localOnly: pending);
      if (!mounted) return;
      if (pending) {
        _showSuccess('Sem internet. A diária ficou guardada no aparelho e '
            'será enviada quando a internet voltar.');
      } else if (entry['status'] == 'existing') {
        _showSuccess('A diária de hoje já estava registrada.');
      } else {
        _showSuccess('Diária registrada!');
      }
    } catch (e) {
      if (mounted) _showError('Erro ao registrar a diária: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _showError(String msg) {
    // O aviso novo entra no lugar do anterior: em fila, o "Entrada salva"
    // ainda aparecia depois da pausa batida.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: wineColor));
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(child: Text(msg)),
        ]),
        backgroundColor: Colors.blue.shade800,
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// Hora em que a diaria foi marcada ('' sem ela), ou 'gestor' na lancada
  /// pelo admin (a hora seria a do lancamento, nao a do dia).
  String _registeredTime(Map<String, dynamic> entry) {
    if (entry['created_by_admin'] == true) return 'gestor';
    final at = DateTime.tryParse(entry['registered_at']?.toString() ?? '');
    return at == null ? '' : DateFormat('HH:mm').format(at);
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
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (context) => const ContentWidth(child: UserChatListScreen())),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: _isLoading && _entries.isEmpty
          ? const StartupLoading(from: 94, to: 99)
          : RefreshIndicator(
              onRefresh: _refresh,
              color: wineColor,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 80, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildClockCard(theme, isDark),
                    const SizedBox(height: 16),
                    _buildStatusCard(theme),
                    const SizedBox(height: 24),
                    _buildAddButton(),
                    const SizedBox(height: 32),
                    _buildPeriodList(theme, isDark),
                  ],
                ),
              ),
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
          Text(
              DateFormat('EEEE, d MMMM yyyy', 'pt_BR')
                  .format(_now)
                  .toUpperCase(),
              style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.1)),
          const SizedBox(height: 8),
          Text(DateFormat('HH:mm:ss').format(_now),
              style: TextStyle(
                  color: theme.primaryColor,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Roboto',
                  fontFeatures: const [FontFeature.tabularFigures()])),
          if (_userName.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white10
                    : Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$_userName  •  Modo diária',
                maxLines: 2,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: theme.textTheme.bodyMedium?.color, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme) {
    final today = _todayEntry;
    final pending = today?['pending'] == true;
    final Color color;
    final String label;
    final String detail;
    if (today == null) {
      color = wineColor;
      label = 'Diária de hoje ainda não registrada';
      detail = '';
    } else if (pending) {
      color = Colors.orange;
      label = 'Diária de hoje guardada no aparelho';
      detail = 'aguardando internet';
    } else {
      color = Colors.green;
      label = 'Diária de hoje registrada';
      final time = _registeredTime(today);
      detail = today['created_by_admin'] == true
          ? 'pelo gestor'
          : (time.isEmpty ? '' : 'às $time');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    color: theme.textTheme.bodyMedium?.color,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
          Text(detail,
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildAddButton() {
    final registered = _todayEntry != null;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: registered || _adding ? null : _addDailyEntry,
        style: ElevatedButton.styleFrom(
          backgroundColor: wineColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.green.withValues(alpha: 0.15),
          disabledForegroundColor: Colors.green.shade700,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: _adding
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2))
            : Icon(registered ? Icons.check_circle : Icons.add_task),
        label: Text(
          registered ? 'DIÁRIA DE HOJE REGISTRADA' : 'ADICIONAR DIÁRIA',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildPeriodList(ThemeData theme, bool isDark) {
    final period = dailyPeriodFor(_now);
    final range = '${DateFormat('dd/MM').format(period.start)} a '
        '${DateFormat('dd/MM').format(period.end)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DIÁRIAS DO PERÍODO ($range): ${_entries.length}',
            style: const TextStyle(
                color: Colors.grey,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1)),
        const SizedBox(height: 12),
        if (_entries.isEmpty)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Nenhuma diária neste período',
                      style: TextStyle(color: Colors.grey, fontSize: 12)))),
        for (final entry in _entries.reversed)
          _buildEntryItem(entry, theme, isDark),
      ],
    );
  }

  Widget _buildEntryItem(
      Map<String, dynamic> entry, ThemeData theme, bool isDark) {
    final day = DateTime.parse(entry['date'].toString());
    final pending = entry['pending'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black26
                  : Colors.black.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(pending ? Icons.cloud_off : Icons.event_available,
                color: pending ? Colors.orange : Colors.green, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
                toBeginningOfSentenceCase(
                    DateFormat("EEEE, dd/MM", 'pt_BR').format(day)),
                style: TextStyle(
                    color: theme.textTheme.bodyMedium?.color,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
          ),
          Text(pending ? 'no aparelho' : _registeredTime(entry),
              style: TextStyle(
                  color: pending
                      ? Colors.orange
                      : theme.textTheme.bodyMedium?.color,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Roboto',
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}
