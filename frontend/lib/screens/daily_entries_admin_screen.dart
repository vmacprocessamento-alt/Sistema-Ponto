import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';
import '../utils/daily_entries.dart';

/// Diarias de uma pessoa no modo diaria, para a gestao: as do periodo da
/// folha (29 a 28), com o horario padrao que a folha mostra em cada uma. O
/// admin ([canEdit]) lanca a diaria de um dia (a pessoa esqueceu de marcar)
/// e apaga a marcada por engano, as duas com motivo (vai para a auditoria).
class DailyEntriesAdminScreen extends StatefulWidget {
  const DailyEntriesAdminScreen(
      {super.key, required this.user, this.canEdit = false});

  final Map<String, dynamic> user;
  final bool canEdit;

  @override
  State<DailyEntriesAdminScreen> createState() =>
      _DailyEntriesAdminScreenState();
}

class _DailyEntriesAdminScreenState extends State<DailyEntriesAdminScreen> {
  static const Color wineColor = Color(0xFF8B0000);

  final _apiService = ApiService();
  // Um dia do periodo mostrado (dailyPeriodFor).
  DateTime _anchor = DateTime.now();
  List<Map<String, dynamic>> _entries = [];
  bool _isLoading = true;
  bool _busy = false;
  String? _error;

  ({DateTime start, DateTime end}) get _period => dailyPeriodFor(_anchor);
  String get _userId => widget.user['id'].toString();
  String get _userName => widget.user['name']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final period = _period;
      final entries = await _apiService.getDailyEntries(
          start: period.start, end: period.end, userId: _userId);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  void _shiftPeriod(int delta) {
    final end = _period.end;
    setState(() => _anchor = DateTime(end.year, end.month + delta, 1));
    _load();
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: wineColor));
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.green));
  }

  String _longDay(DateTime day) => toBeginningOfSentenceCase(
      DateFormat("EEEE, dd/MM/yyyy", 'pt_BR').format(day));

  /// Pede o motivo (obrigatorio) da acao; null se cancelou.
  Future<String?> _askReason({
    required String title,
    required String message,
    required String confirmLabel,
    Color confirmColor = wineColor,
  }) async {
    final controller = TextEditingController();
    String? errorText;
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 3,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Motivo (obrigatório)',
                    border: const OutlineInputBorder(),
                    errorText: errorText,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) {
                  setDialogState(() => errorText = 'Informe o motivo.');
                  return;
                }
                Navigator.pop(dialogContext, text);
              },
              style: ElevatedButton.styleFrom(backgroundColor: confirmColor),
              child: Text(confirmLabel,
                  style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return reason;
  }

  Future<void> _add() async {
    final today = _today;
    final end = _period.end;
    final day = await showDatePicker(
      context: context,
      initialDate: end.isBefore(today) ? end : today,
      firstDate: DateTime(2023),
      lastDate: today,
      locale: const Locale('pt', 'BR'),
      helpText: 'Dia da diária',
    );
    if (day == null || !mounted) return;
    if (_entries.any((entry) => entry['date'] == dailyDayKey(day))) {
      _showError('Já existe diária em ${DateFormat('dd/MM/yyyy').format(day)}.');
      return;
    }
    final reason = await _askReason(
      title: 'Lançar diária',
      message: 'Lançar a diária de $_userName em ${_longDay(day)}?',
      confirmLabel: 'Lançar',
    );
    if (reason == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await _apiService.adminAddDailyEntry(
          userId: _userId, day: day, reason: reason);
      // Mostra o periodo do dia lancado.
      _anchor = day;
      await _load();
      if (mounted) {
        _showSuccess(
            'Diária de ${DateFormat('dd/MM').format(day)} lançada.');
      }
    } catch (e) {
      if (mounted) _showError('Erro ao lançar a diária: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> entry) async {
    final day = DateTime.parse(entry['date'].toString());
    final reason = await _askReason(
      title: 'Apagar diária',
      message: 'Apagar a diária de $_userName em ${_longDay(day)}? Ela sai '
          'da folha e do app da pessoa.',
      confirmLabel: 'Apagar',
      confirmColor: Colors.red,
    );
    if (reason == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await _apiService.adminDeleteDailyEntry(
          entryId: entry['id'].toString(), reason: reason);
      await _load();
      if (mounted) {
        _showSuccess(
            'Diária de ${DateFormat('dd/MM').format(day)} apagada.');
      }
    } catch (e) {
      if (mounted) _showError('Erro ao apagar a diária: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstName = _userName.trim().split(RegExp(r'\s+')).first;
    return Scaffold(
      appBar: AppBar(
        title: Text('Diárias — $firstName',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          _buildPeriodBar(),
          if (_busy) const LinearProgressIndicator(color: wineColor),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: wineColor))
                : _error != null
                    ? _buildError()
                    : RefreshIndicator(
                        onRefresh: _load,
                        color: wineColor,
                        child: _buildList(),
                      ),
          ),
        ],
      ),
      floatingActionButton: widget.canEdit
          ? FloatingActionButton.extended(
              onPressed: _busy || _isLoading ? null : _add,
              backgroundColor: wineColor,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text('Lançar diária',
                  style: TextStyle(color: Colors.white)),
            )
          : null,
    );
  }

  Widget _buildPeriodBar() {
    final period = _period;
    final format = DateFormat('dd/MM/yyyy');
    // Periodo seguinte so quando este ja acabou: nao ha diaria no futuro.
    final canGoForward = period.end.isBefore(_today);
    return Container(
      color: Theme.of(context).cardColor,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Período anterior',
            onPressed: _isLoading ? null : () => _shiftPeriod(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                    '${format.format(period.start)} a '
                    '${format.format(period.end)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
                Text(
                    _isLoading ? '' : 'Total: ${_entries.length} diária(s)',
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Próximo período',
            onPressed:
                _isLoading || !canGoForward ? null : () => _shiftPeriod(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Não foi possível carregar as diárias: $_error',
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Tentar de novo')),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_entries.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(
                child: Text('Nenhuma diária neste período',
                    style: TextStyle(color: Colors.grey))),
          ),
        ],
      );
    }
    final entries = _entries.reversed.toList();
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _buildEntry(entries[index]),
    );
  }

  Widget _buildEntry(Map<String, dynamic> entry) {
    final dayKey = entry['date'].toString();
    final day = DateTime.parse(dayKey);
    final byAdmin = entry['created_by_admin'] == true;
    final String origin;
    if (byAdmin) {
      final by = entry['created_by_name']?.toString() ?? '';
      final reason = entry['admin_reason']?.toString() ?? '';
      origin = 'Lançada pelo gestor${by.isEmpty ? '' : ' ($by)'}'
          '${reason.isEmpty ? '' : ': $reason'}';
    } else {
      final at = DateTime.tryParse(entry['registered_at']?.toString() ?? '');
      origin = [
        if (at != null) 'Marcada às ${DateFormat('HH:mm').format(at)}',
        if (entry['synced_from_offline'] == true) 'sem internet, enviada depois',
      ].join(' • ');
    }
    final format = DateFormat('HH:mm');
    final schedule = dailyStandardSessions(
            _userName, dayKey, widget.user['daily_hours'])
        .map((s) => '${format.format(s.$1)}–${format.format(s.$2)}')
        .join(' · ');

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
            byAdmin ? Icons.admin_panel_settings : Icons.event_available,
            color: byAdmin ? Colors.orange : Colors.green),
        title: Text(_longDay(day),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Text(
            [if (origin.isNotEmpty) origin, 'Folha: $schedule'].join('\n'),
            style: const TextStyle(fontSize: 12)),
        isThreeLine: origin.isNotEmpty,
        trailing: widget.canEdit
            ? IconButton(
                tooltip: 'Apagar diária',
                onPressed: _busy ? null : () => _delete(entry),
                icon: const Icon(Icons.delete_outline, color: Colors.red),
              )
            : null,
      ),
    );
  }
}
