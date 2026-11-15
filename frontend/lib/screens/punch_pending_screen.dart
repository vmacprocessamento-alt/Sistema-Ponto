import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';
import '../utils/batch_entry.dart';
import '../utils/punch_issues.dart';
import '../utils/record_types.dart';
import '../widgets/content_width.dart';

/// Dados e correcoes da aba Pendencias (trocavel nos testes).
class PunchPendingSource {
  const PunchPendingSource();

  /// Pessoas ativas (sem `disabled`), com id, name, role, daily_mode e
  /// created_at (DateTime ou null).
  Future<List<Map<String, dynamic>>> users() async => [
        for (final raw in await ApiService().getUsers())
          if (raw is Map && raw['disabled'] != true && raw['id'] != null)
            {
              ...Map<String, dynamic>.from(raw),
              'created_at': _toDate(raw['created_at']),
            },
      ];

  Future<List<Map<String, dynamic>>> records(DateTime start, DateTime end) async =>
      (await ApiService().getAdminTimeRecords(
        startDate: start.toIso8601String(),
        endDate: end.toIso8601String(),
      ))
          .whereType<Map>()
          .map((record) => Map<String, dynamic>.from(record))
          .toList();

  /// Lanca um ponto para [userId], como o lote do gestor (data real), ligado
  /// a entrada [shiftEntryId] quando houver. Devolve o id.
  Future<String?> createPunch({
    required String userId,
    required String type,
    required DateTime at,
    required String notes,
    String? shiftEntryId,
  }) async {
    final saved = await ApiService().createTimeRecord(
      recordType: type,
      userId: userId,
      timestamp: at.toIso8601String(),
      notes: notes,
      location: 'Gestor (Pendências)',
      extraFields: {
        ...batchRecordFields,
        if (shiftEntryId != null) 'shift_entry_id': shiftEntryId,
      },
    );
    return saved['id']?.toString();
  }

  /// Corrige horario (e tipo) de um ponto: so admin, com motivo e auditoria.
  Future<void> editPunch({
    required String recordId,
    required DateTime at,
    required String reason,
    String? notes,
    String? newType,
  }) =>
      ApiService().updateTimeRecordAdmin(
        recordId: recordId,
        newTimestamp: at.toIso8601String(),
        reason: reason,
        notes: notes,
        newRecordType: newType,
      );

  Future<void> deletePunch(String recordId, String reason) =>
      ApiService().deleteTimeRecordAdmin(recordId: recordId, reason: reason);

  Future<void> markReviewed(List<String> ids) async {
    await ApiService().reviewTimeRecords(ids);
  }

  static DateTime? _toDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse(value?.toString() ?? '');
  }
}

/// ABA PENDENCIAS DA GESTAO (15/11/2026): por pessoa, o que ela deixou de
/// bater no periodo (regras em utils/punch_issues.dart), com a correcao ali
/// mesmo: fechar o turno, lancar a saida real do "Esqueci", ajustar o retorno
/// da pausa, editar ou apagar batida solta, conferir a jornada longa e lancar
/// o ponto do dia sem batida. Lancar ponto vale para admin e gestor (como o
/// lote); editar e apagar, so admin (com motivo, na auditoria).
class PunchPendingScreen extends StatefulWidget {
  const PunchPendingScreen(
      {super.key, this.isAdmin = false, this.source, this.clock});

  final bool isAdmin;
  final PunchPendingSource? source;

  /// Hora de agora (trocavel nos testes).
  final DateTime Function()? clock;

  @override
  State<PunchPendingScreen> createState() => _PunchPendingScreenState();
}

class _PersonIssues {
  _PersonIssues(this.userId, this.name, this.issues);

  final String userId;
  final String name;
  final List<PunchIssue> issues;
}

class _PunchPendingScreenState extends State<PunchPendingScreen> {
  static const Color wineColor = Color(0xFF8B0000);
  static const _periods = [7, 15, 30];
  static final _dayHour = DateFormat('dd/MM HH:mm');

  late final PunchPendingSource _source =
      widget.source ?? const PunchPendingSource();
  int _days = 7;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<_PersonIssues> _people = [];
  int _clean = 0;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime _now() => (widget.clock ?? DateTime.now)();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = _now();
      final from = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: _days - 1));
      // Dois dias antes do periodo: o turno que comecou antes dele.
      final records = await _source.records(
        from.subtract(const Duration(days: 2)),
        DateTime(now.year, now.month, now.day, 23, 59, 59, 999, 999),
      );
      final byUser = <String, List<Map<String, dynamic>>>{};
      for (final record in records) {
        final uid = record['user_id']?.toString();
        if (uid != null) byUser.putIfAbsent(uid, () => []).add(record);
      }
      final people = <_PersonIssues>[];
      var clean = 0;
      for (final user in await _source.users()) {
        final uid = user['id'].toString();
        final mine = byUser[uid] ?? const <Map<String, dynamic>>[];
        // Modo diaria nao bate ponto; gestor e admin so contam se bateram.
        final role = user['role']?.toString() ?? '';
        final punches = user['daily_mode'] != true &&
            (mine.isNotEmpty || (role != 'admin' && role != 'manager'));
        if (!punches) continue;
        final issues = findPunchIssues(
          mine,
          from: from,
          now: now,
          activeSince: user['created_at'] as DateTime?,
        );
        if (issues.isEmpty) {
          clean++;
        } else {
          final name = user['name']?.toString().trim() ?? '';
          people.add(_PersonIssues(uid, name.isEmpty ? 'Sem nome' : name, issues));
        }
      }
      // Quem esqueceu mais primeiro; dia sem ponto pesa menos (pode ser folga).
      int weight(_PersonIssues person) => person.issues
          .where((issue) => issue.kind != PunchIssueKind.missingDay)
          .length;
      people.sort((a, b) {
        final byWeight = weight(b).compareTo(weight(a));
        return byWeight != 0
            ? byWeight
            : b.issues.length.compareTo(a.issues.length);
      });
      if (!mounted) return;
      setState(() {
        _people = people;
        _clean = clean;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Não foi possível carregar: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red : Colors.green,
    ));
  }

  /// Roda a correcao [action], recarrega e avisa.
  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      _snack(done);
      await _load();
    } catch (e) {
      _snack('Não foi possível salvar: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static DateTime? _timeOf(Map<String, dynamic>? record) =>
      DateTime.tryParse(record?['timestamp']?.toString() ?? '');

  static DateTime _earliest(Iterable<DateTime?> moments) => moments
      .whereType<DateTime>()
      .reduce((a, b) => a.isBefore(b) ? a : b);

  /// Saida sugerida: 8h depois da entrada, antes da proxima batida e de agora.
  DateTime _suggestedExit(DateTime entryAt, DateTime? notAfter) => _earliest([
        entryAt.add(const Duration(hours: 8)),
        notAfter?.subtract(const Duration(minutes: 1)),
        _now(),
      ]);

  // --- correcoes ---

  /// Fecha o turno aberto [issue] com a saida na hora escolhida.
  Future<void> _closeShift(String userId, PunchIssue issue) async {
    final entry = issue.entry;
    final entryAt = _timeOf(entry);
    if (entry == null || entryAt == null) return;
    final picked = await _askMoment(
      title: 'Fechar turno',
      message: 'Entrada em ${_dayHour.format(entryAt)}. Escolha a hora em que '
          'a pessoa saiu.',
      initial: _suggestedExit(entryAt, issue.notAfter),
      notBefore: entryAt,
      notAfter: issue.notAfter ?? _now(),
      defaultReason: 'Saída não batida; lançada pelo gestor',
      confirmLabel: 'Fechar turno',
    );
    if (picked == null) return;
    await _run(
      () async {
        await _source.createPunch(
          userId: userId,
          type: 'check_out',
          at: picked.at,
          notes: picked.reason,
          shiftEntryId: entry['id']?.toString(),
        );
      },
      'Turno fechado às ${_dayHour.format(picked.at)}.',
    );
  }

  /// Corrige a hora (e o tipo, se [allowType]) do ponto [record].
  Future<void> _editRecord(
    Map<String, dynamic> record, {
    required String title,
    required String message,
    DateTime? notBefore,
    DateTime? notAfter,
    String defaultReason = '',
    String? notes,
    bool allowType = false,
    String done = 'Ponto corrigido.',
    DateTime? initial,
  }) async {
    final picked = await _askMoment(
      title: title,
      message: message,
      initial: initial ?? _timeOf(record) ?? _now(),
      notBefore: notBefore,
      notAfter: notAfter,
      defaultReason: defaultReason,
      type: allowType ? record['record_type']?.toString() : null,
    );
    if (picked == null) return;
    final type = picked.type;
    await _run(
      () => _source.editPunch(
        recordId: record['id'].toString(),
        at: picked.at,
        reason: picked.reason,
        notes: notes ?? record['notes']?.toString(),
        newType: type != null && type != record['record_type'] ? type : null,
      ),
      done,
    );
  }

  /// Lanca o retorno da pausa deixada aberta ate a saida.
  Future<void> _addPauseReturn(String userId, PunchIssue issue) async {
    final pause = issue.pause;
    final pauseAt = _timeOf(pause);
    if (pause == null || pauseAt == null) return;
    final returnType =
        pause['record_type'] == 'entry_3' ? 'exit_3' : 'break_end';
    final picked = await _askMoment(
      title: 'Lançar retorno da pausa',
      message: 'Pausa em ${_dayHour.format(pauseAt)}. Escolha a hora em que '
          'a pessoa voltou.',
      initial: _earliest([
        pauseAt.add(const Duration(hours: 1)),
        if (issue.notAfter != null)
          issue.notAfter!.subtract(const Duration(minutes: 1)),
        _now(),
      ]),
      notBefore: pauseAt,
      notAfter: issue.notAfter,
      defaultReason: 'Retorno da pausa não batido; lançado pelo gestor',
      confirmLabel: 'Lançar retorno',
    );
    if (picked == null) return;
    await _run(
      () async {
        await _source.createPunch(
          userId: userId,
          type: returnType,
          at: picked.at,
          notes: picked.reason,
          shiftEntryId: issue.entry?['id']?.toString(),
        );
      },
      'Retorno lançado às ${_dayHour.format(picked.at)}.',
    );
  }

  Future<void> _deleteRecord(Map<String, dynamic> record, String what) async {
    final at = _timeOf(record);
    final reason = await _askReason(
      title: 'Apagar $what',
      message: '${recordTypeLabel(record['record_type']?.toString())}'
          '${at == null ? '' : ' de ${_dayHour.format(at)}'} sai da folha e do '
          'app da pessoa; a cópia fica na auditoria.',
    );
    if (reason == null) return;
    await _run(() => _source.deletePunch(record['id'].toString(), reason),
        'Ponto apagado.');
  }

  Future<void> _markRight(Map<String, dynamic> record) async {
    await _run(() => _source.markReviewed([record['id'].toString()]),
        'Marcado como conferido.');
  }

  /// Lanca entrada, saida e (se quiser) a pausa do dia sem batida.
  Future<void> _launchDay(String userId, DateTime day) async {
    final plan = await _askDayPunches(day);
    if (plan == null) return;
    await _run(
      () async {
        String? entryId;
        for (final punch in [
          ...plan.punches.where((punch) => punch.recordType == 'check_in'),
          ...plan.punches.where((punch) => punch.recordType != 'check_in'),
        ]) {
          final id = await _source.createPunch(
            userId: userId,
            type: punch.recordType,
            at: punch.at,
            notes: plan.reason,
            shiftEntryId: punch.recordType == 'check_in' ? null : entryId,
          );
          if (punch.recordType == 'check_in') entryId = id;
        }
      },
      'Ponto de ${DateFormat('dd/MM').format(day)} lançado.',
    );
  }

  // --- janelas ---

  Future<String?> _askReason(
      {required String title, required String message}) async {
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 2,
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
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child:
                  const Text('Apagar', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return reason;
  }

  /// Escolhe data e hora (entre [notBefore] e [notAfter], nunca no futuro),
  /// o motivo e, com [type], o tipo da batida.
  Future<({DateTime at, String reason, String? type})?> _askMoment({
    required String title,
    required String message,
    required DateTime initial,
    DateTime? notBefore,
    DateTime? notAfter,
    String defaultReason = '',
    String confirmLabel = 'Salvar',
    String? type,
  }) async {
    var at = DateTime(initial.year, initial.month, initial.day, initial.hour,
        initial.minute);
    var selectedType = type;
    final reasonController = TextEditingController(text: defaultReason);
    String? error;
    final result = await showDialog<({DateTime at, String reason, String? type})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> pickDate() async {
            final picked = await showDatePicker(
              context: context,
              initialDate: at,
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (picked == null) return;
            setDialogState(() => at = DateTime(
                picked.year, picked.month, picked.day, at.hour, at.minute));
          }

          Future<void> pickTime() async {
            final picked = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(at),
            );
            if (picked == null) return;
            setDialogState(() => at =
                DateTime(at.year, at.month, at.day, picked.hour, picked.minute));
          }

          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(message),
                  const SizedBox(height: 16),
                  if (selectedType != null) ...[
                    DropdownButtonFormField<String>(
                      initialValue: punchTypes.contains(selectedType)
                          ? selectedType
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Tipo da batida',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final option in punchTypes)
                          DropdownMenuItem(
                              value: option,
                              child: Text(recordTypeLabel(option))),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => selectedType = value);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: pickDate,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(DateFormat('dd/MM/yy').format(at)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: pickTime,
                          icon: const Icon(Icons.access_time, size: 18),
                          label: Text(DateFormat('HH:mm').format(at)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: reasonController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Motivo (obrigatório)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
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
                  final reason = reasonController.text.trim();
                  final now = _now();
                  final String? problem;
                  if (notBefore != null && !at.isAfter(notBefore)) {
                    problem = 'Escolha um horário depois de '
                        '${_dayHour.format(notBefore)}.';
                  } else if (at.isAfter(now)) {
                    problem = 'O horário não pode ser no futuro.';
                  } else if (notAfter != null &&
                      notAfter.isBefore(now) &&
                      !at.isBefore(notAfter)) {
                    problem = 'Escolha um horário antes de '
                        '${_dayHour.format(notAfter)} (próxima batida).';
                  } else if (reason.isEmpty) {
                    problem = 'Informe o motivo.';
                  } else {
                    problem = null;
                  }
                  if (problem != null) {
                    setDialogState(() => error = problem);
                    return;
                  }
                  Navigator.pop(dialogContext,
                      (at: at, reason: reason, type: selectedType));
                },
                style: ElevatedButton.styleFrom(backgroundColor: wineColor),
                child: Text(confirmLabel,
                    style: const TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
    reasonController.dispose();
    return result;
  }

  /// Entrada e saida (e a pausa, opcional) do dia [day], com o motivo.
  Future<({List<BatchPunch> punches, String reason})?> _askDayPunches(
      DateTime day) async {
    final times = <String, TimeOfDay?>{
      'check_in': const TimeOfDay(hour: 8, minute: 0),
      'break_start': null,
      'break_end': null,
      'check_out': const TimeOfDay(hour: 17, minute: 0),
    };
    final reasonController =
        TextEditingController(text: 'Ponto não batido; lançado pelo gestor');
    String? error;
    final result =
        await showDialog<({List<BatchPunch> punches, String reason})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> pick(String type) async {
            final picked = await showTimePicker(
              context: context,
              initialTime: times[type] ??
                  (type == 'break_start'
                      ? const TimeOfDay(hour: 12, minute: 0)
                      : const TimeOfDay(hour: 13, minute: 0)),
            );
            if (picked != null) setDialogState(() => times[type] = picked);
          }

          Widget row(String type, {bool optional = false}) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(child: Text(recordTypeLabel(type))),
                    OutlinedButton(
                      onPressed: () => pick(type),
                      child: Text(times[type] == null
                          ? 'Escolher'
                          : times[type]!.format(context)),
                    ),
                    if (optional && times[type] != null)
                      IconButton(
                        tooltip: 'Tirar',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () =>
                            setDialogState(() => times[type] = null),
                      ),
                  ],
                ),
              );

          return AlertDialog(
            title: Text('Lançar ponto de ${DateFormat('dd/MM').format(day)}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Horário antes da entrada vai para o dia '
                      'seguinte (turno da noite).'),
                  const SizedBox(height: 12),
                  row('check_in'),
                  row('break_start', optional: true),
                  row('break_end', optional: true),
                  row('check_out'),
                  const SizedBox(height: 4),
                  TextField(
                    controller: reasonController,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Motivo (obrigatório)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
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
                  final reason = reasonController.text.trim();
                  final String? problem;
                  if (times['check_in'] == null || times['check_out'] == null) {
                    problem = 'Escolha a entrada e a saída.';
                  } else if ((times['break_start'] == null) !=
                      (times['break_end'] == null)) {
                    problem = 'Escolha o início e o retorno da pausa, ou tire '
                        'os dois.';
                  } else if (reason.isEmpty) {
                    problem = 'Informe o motivo.';
                  } else {
                    problem = null;
                  }
                  if (problem != null) {
                    setDialogState(() => error = problem);
                    return;
                  }
                  final punches = planBatchPunches(day, {
                    for (final type in batchFormOrder)
                      if (times[type] case final time?)
                        type: (hour: time.hour, minute: time.minute),
                  });
                  Navigator.pop(
                      dialogContext, (punches: punches, reason: reason));
                },
                style: ElevatedButton.styleFrom(backgroundColor: wineColor),
                child: const Text('Lançar',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
    reasonController.dispose();
    return result;
  }

  // --- tela ---

  static const Map<PunchIssueKind, IconData> _icons = {
    PunchIssueKind.openShift: Icons.logout,
    PunchIssueKind.forgottenExit: Icons.help_outline,
    PunchIssueKind.autoBreakReturn: Icons.free_breakfast_outlined,
    PunchIssueKind.loosePunch: Icons.link_off,
    PunchIssueKind.longShift: Icons.hourglass_bottom,
    PunchIssueKind.missingDay: Icons.event_busy,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ContentWidth(
        maxWidth: ContentWidth.wide,
        child: RefreshIndicator(
          color: wineColor,
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: wineColor))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _header(),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.red)),
                      ),
                    const SizedBox(height: 12),
                    _totals(),
                    const SizedBox(height: 12),
                    for (final person in _people) _personCard(person),
                    if (_error == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text(
                            _people.isEmpty
                                ? 'Nenhuma pendência no período: $_clean '
                                    '${_clean == 1 ? 'pessoa' : 'pessoas'} '
                                    'com o ponto em dia.'
                                : '$_clean '
                                    '${_clean == 1 ? 'pessoa' : 'pessoas'} '
                                    'sem pendência no período.',
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'O que a equipe deixou de bater: turno sem saída (inclusive de um '
          'dia para o outro), "Esqueci" sem o horário real, pausa sem '
          'retorno, batida solta, jornada de mais de 16h e dia útil sem '
          'nenhuma batida. Abra a pessoa e corrija ali mesmo'
          '${widget.isAdmin ? '' : ' (editar e apagar: só o admin)'}.',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final days in _periods)
              ChoiceChip(
                label: Text('$days dias'),
                selected: _days == days,
                selectedColor: wineColor.withValues(alpha: 0.15),
                onSelected: (selected) {
                  if (!selected || _days == days) return;
                  setState(() => _days = days);
                  _load();
                },
              ),
            IconButton(
              tooltip: 'Atualizar',
              icon: const Icon(Icons.refresh, color: wineColor),
              onPressed: _load,
            ),
          ],
        ),
      ],
    );
  }

  Widget _totals() {
    final counts = <PunchIssueKind, int>{};
    for (final person in _people) {
      for (final issue in person.issues) {
        counts[issue.kind] = (counts[issue.kind] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final kind in PunchIssueKind.values)
          if (counts[kind] case final count?)
            Chip(
              avatar: Icon(_icons[kind], size: 18, color: wineColor),
              label: Text('${punchIssueLabel(kind)}: $count'),
            ),
      ],
    );
  }

  /// Botoes de correcao da pendencia [issue] de [userId].
  List<Widget> _actions(String userId, PunchIssue issue) {
    final admin = widget.isAdmin;
    Widget button(String label, IconData icon, VoidCallback onPressed,
            {Color color = wineColor}) =>
        TextButton.icon(
          onPressed: _busy ? null : onPressed,
          style: TextButton.styleFrom(
            foregroundColor: color,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: Icon(icon, size: 18),
          label: Text(label),
        );
    final record = issue.record;
    final entry = issue.entry;
    switch (issue.kind) {
      case PunchIssueKind.openShift:
        return [
          button('Fechar turno', Icons.logout, () => _closeShift(userId, issue)),
          if (admin && entry != null)
            button('Apagar entrada', Icons.delete_outline,
                () => _deleteRecord(entry, 'entrada'),
                color: Colors.red),
        ];
      case PunchIssueKind.forgottenExit:
        if (!admin || record == null) return const [];
        return [
          button('Lançar saída real', Icons.edit_calendar, () {
            _editRecord(
              record,
              title: 'Lançar saída real',
              message: 'Turno de ${_dayHour.format(issue.at)} fechado no '
                  '"Esqueci". Escolha a hora em que a pessoa saiu.',
              notBefore: issue.notBefore,
              notAfter: issue.notAfter,
              defaultReason: 'Saída esquecida; horário real lançado pelo gestor',
              notes: 'Saída esquecida; horário lançado pelo gestor',
              done: 'Saída lançada.',
              initial: _suggestedExit(issue.at, issue.notAfter),
            );
          }),
        ];
      case PunchIssueKind.autoBreakReturn:
        if (record == null) {
          return [
            button('Lançar retorno', Icons.free_breakfast_outlined,
                () => _addPauseReturn(userId, issue)),
          ];
        }
        return [
          if (admin)
            button('Ajustar retorno', Icons.edit, () {
              _editRecord(
                record,
                title: 'Ajustar retorno da pausa',
                message: 'Pausa de ${_dayHour.format(issue.at)}. Escolha a '
                    'hora em que a pessoa voltou.',
                notBefore: issue.notBefore,
                notAfter: issue.notAfter,
                defaultReason:
                    'Retorno da pausa não batido; ajustado pelo gestor',
                done: 'Retorno ajustado.',
              );
            }),
          button('Está certo', Icons.check, () => _markRight(record)),
        ];
      case PunchIssueKind.loosePunch:
        if (!admin || record == null) return const [];
        return [
          button('Editar', Icons.edit, () {
            _editRecord(
              record,
              title: 'Editar batida',
              message: 'Corrija o horário ou o tipo da batida (ex.: era a '
                  'Saída, não a Pausa).',
              allowType: true,
            );
          }),
          button('Apagar', Icons.delete_outline,
              () => _deleteRecord(record, 'batida'),
              color: Colors.red),
        ];
      case PunchIssueKind.longShift:
        if (record == null) return const [];
        return [
          if (admin)
            button('Editar saída', Icons.edit, () {
              _editRecord(
                record,
                title: 'Editar saída',
                message: 'Entrada em ${_dayHour.format(issue.at)}. Corrija a '
                    'hora da saída.',
                notBefore: issue.notBefore,
                notAfter: issue.notAfter,
                done: 'Saída corrigida.',
              );
            }),
          if (admin && entry != null)
            button('Editar entrada', Icons.edit, () {
              _editRecord(
                entry,
                title: 'Editar entrada',
                message: 'Corrija a hora da entrada.',
                notAfter: _timeOf(record),
                done: 'Entrada corrigida.',
              );
            }),
          button('Está certo', Icons.check, () => _markRight(record)),
        ];
      case PunchIssueKind.missingDay:
        return [
          button('Lançar ponto', Icons.add_circle_outline,
              () => _launchDay(userId, issue.at)),
        ];
    }
  }

  Widget _personCard(_PersonIssues person) {
    final byKind = <PunchIssueKind, int>{};
    for (final issue in person.issues) {
      byKind[issue.kind] = (byKind[issue.kind] ?? 0) + 1;
    }
    final summary = [
      for (final kind in PunchIssueKind.values)
        if (byKind[kind] case final count?) '${punchIssueLabel(kind)}: $count',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        key: PageStorageKey('pendencias-${person.userId}'),
        initiallyExpanded: _expanded.contains(person.userId),
        onExpansionChanged: (open) => open
            ? _expanded.add(person.userId)
            : _expanded.remove(person.userId),
        leading: CircleAvatar(
          backgroundColor: wineColor,
          foregroundColor: Colors.white,
          child: Text('${person.issues.length}'),
        ),
        title: Text(person.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(summary, style: const TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
        children: [
          for (final issue in person.issues)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 8),
                    child: Icon(_icons[issue.kind],
                        size: 18,
                        color: issue.kind == PunchIssueKind.missingDay
                            ? Colors.grey
                            : Colors.orange),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(punchIssueLabel(issue.kind),
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600)),
                        Text(issue.text, style: const TextStyle(fontSize: 13)),
                        Wrap(children: _actions(person.userId, issue)),
                      ],
                    ),
                  ),
                  Text(DateFormat('dd/MM').format(issue.at),
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
