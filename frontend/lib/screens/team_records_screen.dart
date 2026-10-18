import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'package:intl/intl.dart';
import '../widgets/export_dialog.dart';
import 'daily_entries_admin_screen.dart';

class TeamRecordsScreen extends StatefulWidget {
  final bool canEdit;

  const TeamRecordsScreen({super.key, this.canEdit = false});

  @override
  State<TeamRecordsScreen> createState() => _TeamRecordsScreenState();
}

class _TeamRecordsScreenState extends State<TeamRecordsScreen> {
  final _apiService = ApiService();
  List<dynamic> _records = [];
  List<dynamic> _users = [];
  dynamic _selectedUserId;
  bool _isLoading = true;

  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now();
  String _filterType = 'diário'; // diário, semanal, mensal

  static const Color wineColor = Color(0xFF8B0000);

  @override
  void initState() {
    super.initState();
    _setInitialDates();
    _fetchInitialData();
  }

  // Fim do dia com microssegundos: o backend grava 23:59:59.123456, que na
  // comparacao de texto fica depois de "23:59:59" e sumia da lista.
  static DateTime _endOfDay(DateTime day) =>
      DateTime(day.year, day.month, day.day, 23, 59, 59, 999, 999);

  void _setInitialDates() {
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, now.day);
    _endDate = _endOfDay(now);
  }

  Future<void> _fetchInitialData() async {
    setState(() => _isLoading = true);
    try {
      final users = await _apiService.getUsers();
      setState(() => _users = users);
      await _fetchRecords();
    } catch (e) {
      debugPrint('Erro: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchRecords() async {
    try {
      final records = await _apiService.getAdminTimeRecords(
        userId: _selectedUserId,
        startDate: _startDate.toIso8601String(),
        endDate: _endDate.toIso8601String(),
      );
      setState(() => _records = records);
    } catch (e) {
      debugPrint('Erro: $e');
    }
  }

  void _changeFilter(String type) {
    setState(() {
      _filterType = type;
      final now = DateTime.now();
      if (type == 'diário') {
        _startDate = DateTime(now.year, now.month, now.day);
        _endDate = _endOfDay(now);
      } else if (type == 'semanal') {
        // Segunda-feira pelo calendario, nao por 24h a menos.
        _startDate = DateTime(now.year, now.month, now.day - (now.weekday - 1));
        _endDate = _endOfDay(now);
      } else if (type == 'mensal') {
        _startDate = DateTime(now.year, now.month, 1);
        _endDate = _endOfDay(DateTime(now.year, now.month + 1, 0));
      }
    });
    _fetchRecords();
  }

  /// Periodo livre. So com dia/semana/mes do calendario, a vespera ficava
  /// fora de alcance numa segunda-feira dia 1, e a saida esquecida (gravada
  /// no dia da entrada) ou a entrada do turno da noite nao apareciam para
  /// corrigir; o fechamento 29 a 28 tambem nao cabia em nenhum filtro.
  Future<void> _pickPeriod() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      // O lote do gestor aceita datas ate um ano a frente.
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: DateTimeRange(
        start: DateTime(_startDate.year, _startDate.month, _startDate.day),
        end: DateTime(_endDate.year, _endDate.month, _endDate.day),
      ),
    );
    if (picked == null) return;
    setState(() {
      _filterType = 'período';
      _startDate = picked.start;
      _endDate = _endOfDay(picked.end);
    });
    _fetchRecords();
  }

  Future<void> _showExportDialog() async {
    final selectedUser = _selectedUserId != null
        ? _users.firstWhere((u) => u['id'] == _selectedUserId,
            orElse: () => null)
        : null;

    showDialog(
      context: context,
      builder: (context) => ExportDialog(
        initialUser: selectedUser,
        isScratch: false,
      ),
    );
  }

  Future<void> _showEditRecordDialog(Map<String, dynamic> record) async {
    DateTime selectedDateTime = DateTime.parse(record['timestamp']).toLocal();
    final notesController =
        TextEditingController(text: record['notes']?.toString() ?? '');
    final reasonController = TextEditingController();
    String? reasonError;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> pickDate() async {
              final picked = await showDatePicker(
                context: context,
                initialDate: selectedDateTime,
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked == null) return;
              setDialogState(() {
                selectedDateTime = DateTime(
                  picked.year,
                  picked.month,
                  picked.day,
                  selectedDateTime.hour,
                  selectedDateTime.minute,
                  selectedDateTime.second,
                );
              });
            }

            Future<void> pickTime() async {
              final picked = await showTimePicker(
                context: context,
                initialTime: TimeOfDay.fromDateTime(selectedDateTime),
              );
              if (picked == null) return;
              setDialogState(() {
                selectedDateTime = DateTime(
                  selectedDateTime.year,
                  selectedDateTime.month,
                  selectedDateTime.day,
                  picked.hour,
                  picked.minute,
                  0,
                );
              });
            }

            return AlertDialog(
              title: const Text('Editar ponto'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      record['record_type']
                          .toString()
                          .replaceAll('_', ' ')
                          .toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: pickDate,
                      icon: const Icon(Icons.calendar_today),
                      label: Text(
                          DateFormat('dd/MM/yyyy').format(selectedDateTime)),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: pickTime,
                      icon: const Icon(Icons.access_time),
                      label:
                          Text(DateFormat('HH:mm:ss').format(selectedDateTime)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: notesController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Observacao',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: reasonController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: 'Motivo da edicao (obrigatorio)',
                        border: const OutlineInputBorder(),
                        errorText: reasonError,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (reasonController.text.trim().isEmpty) {
                      setDialogState(
                          () => reasonError = 'Informe o motivo da edicao.');
                      return;
                    }
                    Navigator.pop(dialogContext, true);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: wineColor),
                  child: const Text('Salvar',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) {
      notesController.dispose();
      reasonController.dispose();
      return;
    }

    try {
      final notes = notesController.text.trim();
      final reason = reasonController.text.trim();

      await _apiService.updateTimeRecordAdmin(
        recordId: record['id'].toString(),
        newTimestamp: selectedDateTime.toIso8601String(),
        notes: notes,
        reason: reason,
      );
      notesController.dispose();
      reasonController.dispose();
      await _fetchRecords();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ponto editado pelo admin.'),
          backgroundColor: wineColor,
        ),
      );
    } catch (e) {
      notesController.dispose();
      reasonController.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao editar ponto: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildFilterBar(),
            _buildPeriodSelector(),
            if (_selectedDailyUser != null) _buildDailyModeBanner(),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: wineColor))
                  : _buildRecordsList(),
            ),
          ],
        ),
      ),
      floatingActionButton: widget.canEdit
          ? FloatingActionButton(
              onPressed: _showExportDialog,
              backgroundColor: wineColor,
              child: const Icon(Icons.download, color: Colors.white),
            )
          : null,
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: ['diário', 'semanal', 'mensal'].map((type) {
          final isSelected = _filterType == type;
          return Expanded(
            child: GestureDetector(
              onTap: () => _changeFilter(type),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? wineColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: isSelected
                          ? Colors.transparent
                          : Colors.grey.withValues(alpha: 0.3)),
                ),
                alignment: Alignment.center,
                child: Text(type.toUpperCase(),
                    style: TextStyle(
                        color: isSelected ? Colors.white : Colors.grey,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<dynamic>(
              initialValue: _selectedUserId,
              dropdownColor: Theme.of(context).cardColor,
              decoration: const InputDecoration(
                  labelText: 'Funcionário',
                  isDense: true,
                  border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: null, child: Text('Todos')),
                ..._users.map((u) =>
                    DropdownMenuItem(value: u['id'], child: Text(u['name'])))
              ],
              onChanged: (val) {
                setState(() => _selectedUserId = val);
                _fetchRecords();
              },
            ),
          ),
          const SizedBox(width: 12),
          InkWell(
            onTap: _pickPeriod,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(DateFormat('dd/MM').format(_startDate),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 12)),
                      const Text('até',
                          style: TextStyle(color: Colors.grey, fontSize: 10)),
                      Text(DateFormat('dd/MM').format(_endDate),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.date_range, color: wineColor, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Funcionario escolhido, se ele esta no modo diaria: o ponto dele sao as
  /// diarias, que ficam numa tela propria.
  Map<String, dynamic>? get _selectedDailyUser {
    if (_selectedUserId == null) return null;
    for (final user in _users) {
      if (user is Map &&
          user['id'] == _selectedUserId &&
          user['daily_mode'] == true) {
        return Map<String, dynamic>.from(user);
      }
    }
    return null;
  }

  Widget _buildDailyModeBanner() {
    final user = _selectedDailyUser!;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: wineColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: wineColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_available, color: wineColor, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Modo diária: o ponto desta pessoa são as diárias.',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DailyEntriesAdminScreen(
                    user: user, canEdit: widget.canEdit),
              ),
            ),
            child: const Text('VER DIÁRIAS',
                style: TextStyle(color: wineColor, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _recordUserName(Map<String, dynamic> record) {
    final directName = record['user_name'] ??
        record['employee_name'] ??
        record['name'] ??
        record['full_name'];
    if (directName != null && directName.toString().trim().isNotEmpty) {
      return directName.toString().trim();
    }

    final userId = record['user_id']?.toString();
    if (userId == null || userId.isEmpty) return 'Sem nome';

    for (final user in _users) {
      if (user is Map && user['id']?.toString() == userId) {
        final name = user['name']?.toString().trim();
        if (name != null && name.isNotEmpty) return name;
      }
    }

    return 'Sem nome';
  }

  Widget _buildRecordsList() {
    if (_records.isEmpty) {
      return const Center(
          child: Text('Nenhum registro no período',
              style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _records.length,
      itemBuilder: (context, index) {
        final r = _records[index];
        final record = Map<String, dynamic>.from(r as Map);
        final time = DateTime.parse(r['timestamp']).toLocal();
        final userName = _recordUserName(record);
        final isEditedByAdmin = r['edited_by_admin'] == true;
        final notes =
            r['notes']?.toString().replaceAll('Editado pelo admin', '').trim();
        final editReason = r['last_admin_edit_reason']?.toString().trim();
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            title: Row(
              children: [
                Text(
                  r['record_type']
                      .toString()
                      .replaceAll('_', ' ')
                      .toUpperCase(),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    userName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(DateFormat('HH:mm:ss').format(time)),
                if (notes != null && notes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(notes,
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
                if (isEditedByAdmin) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Editado pelo admin',
                    style: TextStyle(
                        color: wineColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                  if (editReason != null && editReason.isNotEmpty)
                    Text(
                      'Motivo: $editReason',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(DateFormat('dd/MM/yyyy').format(time),
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
                if (widget.canEdit) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Editar ponto',
                    icon: const Icon(Icons.edit, color: wineColor, size: 20),
                    onPressed: () =>
                        _showEditRecordDialog(Map<String, dynamic>.from(r)),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
