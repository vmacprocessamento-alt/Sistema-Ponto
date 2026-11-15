import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';
import '../utils/punch_issues.dart';
import '../widgets/content_width.dart';

/// Dados da aba Pendencias (trocavel nos testes).
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

  static DateTime? _toDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse(value?.toString() ?? '');
  }
}

/// ABA PENDENCIAS DA GESTAO (15/11/2026): por pessoa, o que ela deixou de
/// bater no periodo (regras em utils/punch_issues.dart). Responde "o ponto
/// esta certo ou a equipe esta deixando de bater, principalmente de um dia
/// para o outro?" sem o gestor abrir dia por dia em Registros.
class PunchPendingScreen extends StatefulWidget {
  const PunchPendingScreen({super.key, this.source, this.clock});

  final PunchPendingSource? source;

  /// Hora de agora (trocavel nos testes).
  final DateTime Function()? clock;

  @override
  State<PunchPendingScreen> createState() => _PunchPendingScreenState();
}

class _PersonIssues {
  _PersonIssues(this.name, this.issues);

  final String name;
  final List<PunchIssue> issues;
}

class _PunchPendingScreenState extends State<PunchPendingScreen> {
  static const Color wineColor = Color(0xFF8B0000);
  static const _periods = [7, 15, 30];

  late final PunchPendingSource _source =
      widget.source ?? const PunchPendingSource();
  int _days = 7;
  bool _loading = true;
  String? _error;
  List<_PersonIssues> _people = [];
  int _clean = 0;

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
          people.add(_PersonIssues(
              user['name']?.toString().trim().isNotEmpty == true
                  ? user['name'].toString().trim()
                  : 'Sem nome',
              issues));
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
        const Text(
          'O que a equipe deixou de bater: turno sem saída (inclusive de um '
          'dia para o outro), "Esqueci" sem o horário real, pausa sem '
          'retorno, batida solta, jornada de mais de 16h e dia útil sem '
          'nenhuma batida. Corrija em Registros.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
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
        leading: CircleAvatar(
          backgroundColor: wineColor,
          foregroundColor: Colors.white,
          child: Text('${person.issues.length}'),
        ),
        title: Text(person.name,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(summary, style: const TextStyle(fontSize: 12)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
