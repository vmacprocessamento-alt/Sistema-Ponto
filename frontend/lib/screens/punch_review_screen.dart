import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../utils/punch_review.dart';
import '../utils/record_types.dart';
import '../widgets/content_width.dart';

/// ABA CONFERENCIA DA GESTAO (03/11/2026). Batidas que passaram mas merecem um
/// olhar (offline enviada muito depois, relogio do celular diferente, outro
/// fuso: utils/punch_review.dart) e as que o servidor recusou
/// (relogio mexido, offline velha, GPS fora do Brasil). O gestor confere e
/// marca "Conferido"; a batida sai da lista.
class PunchReviewScreen extends StatefulWidget {
  const PunchReviewScreen({super.key, this.source});

  /// De onde vem os dados; null: o backend e o Firestore (ApiService).
  final PunchReviewSource? source;

  @override
  State<PunchReviewScreen> createState() => _PunchReviewScreenState();
}

/// Dados da aba Conferencia (trocavel nos testes).
class PunchReviewSource {
  const PunchReviewSource();

  /// Nome de cada usuario, pelo id.
  Future<Map<String, String>> names() async => {
        for (final user in await ApiService().getUsers())
          if (user is Map && user['id'] != null)
            user['id'].toString(): user['name']?.toString() ?? '',
      };

  Future<List<Map<String, dynamic>>> records(DateTime start, DateTime end) async =>
      (await ApiService().getAdminTimeRecords(
        startDate: start.toIso8601String(),
        endDate: end.toIso8601String(),
      ))
          .whereType<Map>()
          .map((record) => Map<String, dynamic>.from(record))
          .toList();

  Future<List<Map<String, dynamic>>> rejections(int days) =>
      ApiService().getPunchRejections(days: days);

  Future<int> review(List<String> ids) => ApiService().reviewTimeRecords(ids);
}

class _PunchReviewScreenState extends State<PunchReviewScreen> {
  static const Color wineColor = Color(0xFF8B0000);
  static const _periods = [7, 30];

  late final PunchReviewSource _source =
      widget.source ?? const PunchReviewSource();
  final Map<String, String> _names = {};
  List<Map<String, dynamic>> _toReview = [];
  List<Map<String, dynamic>> _rejections = [];
  final Set<String> _busy = {};
  int _days = 7;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_names.isEmpty) _names.addAll(await _source.names());
      final now = DateTime.now();
      final since = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: _days - 1));
      final end = DateTime(now.year, now.month, now.day, 23, 59, 59, 999, 999);
      final toReview = (await _source.records(since, end))
          .where((record) => reviewReasons(record).isNotEmpty)
          .toList();
      List<Map<String, dynamic>> rejections;
      try {
        rejections = await _source.rejections(_days);
      } catch (e) {
        debugPrint('Tentativas recusadas indisponiveis: $e');
        rejections = [];
      }
      if (!mounted) return;
      setState(() {
        _toReview = toReview;
        _rejections = rejections;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Não foi possível carregar: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _name(Map<String, dynamic> record) {
    final direct = record['user_name']?.toString().trim();
    if (direct != null && direct.isNotEmpty) return direct;
    final name = _names[record['user_id']?.toString() ?? '']?.trim();
    return name == null || name.isEmpty ? 'Sem nome' : name;
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red : Colors.green,
    ));
  }

  Future<void> _markReviewed(List<Map<String, dynamic>> records) async {
    final ids = records
        .map((record) => record['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
    setState(() => _busy.addAll(ids));
    try {
      var count = 0;
      // O servidor aceita ate 200 por vez.
      for (var start = 0; start < ids.length; start += 200) {
        final end = start + 200 < ids.length ? start + 200 : ids.length;
        count += await _source.review(ids.sublist(start, end));
      }
      if (!mounted) return;
      setState(() =>
          _toReview.removeWhere((record) => ids.contains(record['id'])));
      _snack(count == 1
          ? 'Batida marcada como conferida.'
          : '$count batidas marcadas como conferidas.');
    } catch (e) {
      _snack('Não foi possível marcar: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy.removeAll(ids));
    }
  }

  Future<void> _confirmReviewAll() async {
    final total = _toReview.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Marcar todas como conferidas?'),
        content: Text('As $total batidas da lista saem da Conferência. '
            'Faça isso só depois de olhar cada uma.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: wineColor),
            child: const Text('Marcar todas',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) await _markReviewed(List.of(_toReview));
  }

  Future<void> _openMap(Map<String, dynamic> record) async {
    final uri = recordMapUri(record);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _snack('Não foi possível abrir o mapa.', error: true);
    }
  }

  static String _when(Object? value) {
    final moment = DateTime.tryParse(value?.toString() ?? '');
    return moment == null
        ? '-'
        : DateFormat('dd/MM/yyyy HH:mm').format(moment);
  }

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
                    _rejectionsSection(),
                    const SizedBox(height: 12),
                    _reviewSection(),
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
          'Batidas para conferir: offline enviadas muito depois, relógio do '
          'celular diferente ou outro fuso. Olhe cada uma (hora, local no '
          'mapa) e toque em Conferido. Conferir é opcional: as batidas já '
          'contam na folha. O que dá para provar que é jeitinho o servidor '
          'já recusa e aparece em Tentativas recusadas.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final days in _periods)
              ChoiceChip(
                label: Text('Últimos $days dias'),
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

  Widget _rejectionsSection() {
    return Card(
      child: ExpansionTile(
        leading: Icon(Icons.block,
            color: _rejections.isEmpty ? Colors.grey : Colors.red),
        title: Text('Tentativas recusadas (${_rejections.length})',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: const Text('Batidas que o servidor não aceitou',
            style: TextStyle(fontSize: 12)),
        children: _rejections.isEmpty
            ? const [
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Nenhuma no período.',
                      style: TextStyle(color: Colors.grey)),
                ),
              ]
            : [
                for (final item in _rejections)
                  ListTile(
                    dense: true,
                    title: Text(
                        '${_name(item)} · '
                        '${recordTypeLabel(item['record_type']?.toString())}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      '${rejectionReasonLabel(item['reason']?.toString())}\n'
                      'Hora no celular: ${_when(item['device_timestamp'])}'
                      '${item['offline'] == true ? ' (offline)' : ''} · '
                      'tentativa em ${_when(item['created_at_local'])}',
                    ),
                    isThreeLine: true,
                  ),
              ],
      ),
    );
  }

  Widget _reviewSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Para conferir (${_toReview.length})',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            if (_toReview.length > 1)
              TextButton.icon(
                onPressed: _busy.isEmpty ? _confirmReviewAll : null,
                icon: const Icon(Icons.done_all, color: wineColor),
                label: const Text('Marcar todas',
                    style: TextStyle(color: wineColor)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_toReview.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('Nada para conferir no período.',
                  style: TextStyle(color: Colors.grey)),
            ),
          ),
        for (final record in _toReview) _reviewCard(record),
      ],
    );
  }

  Widget _reviewCard(Map<String, dynamic> record) {
    final id = record['id']?.toString() ?? '';
    final reasons = reviewReasons(record);
    final busy = _busy.contains(id);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${_name(record)} · '
              '${recordTypeLabel(record['record_type']?.toString())}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text('Registrada: ${_when(record['timestamp'])}',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 6),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2, right: 6),
                      child: Icon(Icons.warning_amber_rounded,
                          size: 16, color: Colors.orange),
                    ),
                    Expanded(
                        child: Text(reason,
                            style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                if (recordMapUri(record) != null)
                  TextButton.icon(
                    onPressed: () => _openMap(record),
                    icon: const Icon(Icons.map_outlined, color: wineColor),
                    label: const Text('Ver no mapa',
                        style: TextStyle(color: wineColor)),
                  ),
                ElevatedButton.icon(
                  onPressed: busy || id.isEmpty
                      ? null
                      : () => _markReviewed([record]),
                  style: ElevatedButton.styleFrom(backgroundColor: wineColor),
                  icon: busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check, color: Colors.white),
                  label: const Text('Conferido',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
