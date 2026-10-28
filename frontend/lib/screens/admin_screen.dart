import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import '../services/api_service.dart';
import '../utils/batch_entry.dart';
import '../utils/cpf.dart';
import '../utils/shift_records.dart';
import '../utils/timesheet.dart';
import 'daily_entries_admin_screen.dart';
import 'team_records_screen.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  // Cores da Empresa
  static const Color wineColor = Color(0xFF8B0000);
  final _apiService = ApiService();
  bool _isAdmin = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkRole();
  }

  Future<void> _checkRole() async {
    try {
      final user = await _apiService.getCurrentUser();
      setState(() {
        _isAdmin = user['role'] == 'admin';
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Erro ao verificar cargo: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: wineColor));
    }

    return DefaultTabController(
      length: _isAdmin ? 5 : 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('PAINEL DO GESTOR',
              style:
                  TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          bottom: TabBar(
            labelColor: wineColor,
            unselectedLabelColor: Colors.grey,
            indicatorColor: wineColor,
            tabs: [
              const Tab(icon: Icon(Icons.monitor_heart), text: 'Resumo'),
              const Tab(icon: Icon(Icons.people), text: 'Usuários'),
              const Tab(icon: Icon(Icons.list_alt), text: 'Registros'),
              const Tab(icon: Icon(Icons.access_time), text: 'Liberações'),
              if (_isAdmin)
                const Tab(
                    icon: Icon(Icons.add_circle_outline), text: 'Add Ponto'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            const _TeamStatusTab(),
            const _UsersListTab(),
            TeamRecordsScreen(canEdit: _isAdmin),
            _ScheduleApprovalsTab(isAdmin: _isAdmin),
            if (_isAdmin) const _ManualEntryTab(),
          ],
        ),
      ),
    );
  }
}

class _UsersListTab extends StatefulWidget {
  const _UsersListTab();

  @override
  State<_UsersListTab> createState() => _UsersListTabState();
}

class _UsersListTabState extends State<_UsersListTab> {
  final _apiService = ApiService();
  List<dynamic> _users = [];
  bool _isLoading = true;
  bool _isAdmin = false;

  static const Color wineColor = Color(0xFF8B0000);

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      final user = await _apiService.getCurrentUser();
      _isAdmin = user['role'] == 'admin';
      await _fetchUsers();
    } catch (e) {
      debugPrint('Erro init usuários: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchUsers({bool forceRefresh = false}) async {
    try {
      final users = await _apiService.getUsers(forceRefresh: forceRefresh);
      setState(() => _users = users);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: wineColor),
        );
      }
    }
  }

  void _editUser(dynamic user) {
    showDialog(
      context: context,
      builder: (context) => UserEditDialog(
        user: user,
        onSave: () => _fetchUsers(),
      ),
    );
  }

  void _openDailyEntries(dynamic user) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DailyEntriesAdminScreen(
          user: Map<String, dynamic>.from(user as Map),
          canEdit: _isAdmin,
        ),
      ),
    );
  }

  Future<void> _createUser() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const UserCreateDialog(),
    );
    if (created == null || !mounted) return;
    await _fetchUsers(forceRefresh: true);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AccessMessageDialog(
        name: created['name']?.toString() ?? '',
        cpf: created['cpf']?.toString() ?? '',
        password: created['password']?.toString() ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: wineColor));
    }

    return Scaffold(
      floatingActionButton: _isAdmin
          ? FloatingActionButton.extended(
              onPressed: _createUser,
              backgroundColor: wineColor,
              icon: const Icon(Icons.person_add, color: Colors.white),
              label: const Text('Novo usuário',
                  style: TextStyle(color: Colors.white)),
            )
          : null,
      body: RefreshIndicator(
        // Puxar a lista para baixo e pedido explicito de dado novo: ignora o
        // cache de 5 min do quadro de pessoal.
        onRefresh: () => _fetchUsers(forceRefresh: true),
        color: wineColor,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
          itemCount: _users.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final user = _users[index];
            String role = user['role'] ?? '-';
            if (role == 'intern') role = 'Estagiário';
            if (role == 'employee') role = 'Funcionário';
            final jobTitle = (user['job_title'] ?? role).toString();
            final dailyTag = user['daily_mode'] == true ? ' • Diária' : '';
            final cpf = cpfDigits(user['cpf']?.toString());
            final firstAccess = user['must_change_password'] == true
                ? ' • Aguardando primeiro acesso'
                : '';

            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: wineColor,
                  child: Text(user['name'][0].toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                title: Text(user['name'],
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                    '$role • $jobTitle • ${user['daily_hours']}h/dia$dailyTag'
                    '\nCPF: ${cpf.length == 11 ? formatCpf(cpf) : 'não informado'}'
                    '$firstAccess',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (user['daily_mode'] == true)
                      IconButton(
                        tooltip: 'Diárias',
                        icon: const Icon(Icons.event_available,
                            color: wineColor, size: 22),
                        onPressed: () => _openDailyEntries(user),
                      ),
                    if (_isAdmin)
                      const Icon(Icons.edit, color: wineColor, size: 20),
                  ],
                ),
                onTap: _isAdmin ? () => _editUser(user) : null,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ScheduleApprovalsTab extends StatefulWidget {
  final bool isAdmin;

  const _ScheduleApprovalsTab({required this.isAdmin});

  @override
  State<_ScheduleApprovalsTab> createState() => _ScheduleApprovalsTabState();
}

class _ScheduleApprovalsTabState extends State<_ScheduleApprovalsTab> {
  static const wineColor = Color(0xFF8B0000);
  final _apiService = ApiService();
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _requests = [];
  bool _loading = true;
  String? _decidingId;
  String _view = 'pending';
  String _historyStatus = 'all';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // 1 min em vez de 15s: liberacao nao e tempo real e cada ciclo custa
    // leitura do Firestore (a cota diaria ja estourou uma vez por causa disso).
    _timer =
        Timer.periodic(const Duration(minutes: 1), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final requests = await _apiService.getScheduleApprovalRequests(
          status: _view == 'pending' ? 'pending' : null);
      if (mounted) setState(() => _requests = requests);
    } catch (e) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erro ao carregar liberações: $e'),
          backgroundColor: wineColor,
        ));
      }
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  String _formatTimestamp(dynamic value) {
    final DateTime? parsed;
    if (value is Timestamp) {
      parsed = value.toDate();
    } else if (value is DateTime) {
      parsed = value;
    } else {
      parsed = DateTime.tryParse(value?.toString() ?? '');
    }
    if (parsed == null) return value?.toString() ?? '-';
    return DateFormat('dd/MM/yyyy HH:mm:ss').format(parsed.toLocal());
  }

  List<Map<String, dynamic>> get _visibleRequests {
    if (_view == 'pending') return _requests;
    final query = _searchController.text.trim().toLowerCase();
    return _requests.where((request) {
      final status = request['status']?.toString() ?? '';
      if (status == 'pending') return false;
      if (_historyStatus != 'all' && status != _historyStatus) return false;
      if (query.isEmpty) return true;
      final searchable = [
        request['user_name'],
        request['user_email'],
        request['notes'],
        request['decided_by_name'],
        request['decision_reason'],
      ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
      return searchable.contains(query);
    }).toList();
  }

  Future<void> _changeView(String view) async {
    if (_view == view) return;
    setState(() {
      _view = view;
      _loading = true;
    });
    await _load();
  }

  Future<void> _decide(Map<String, dynamic> request, bool approve) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? 'Liberar horário?' : 'Recusar solicitação?'),
        content: TextField(
          controller: reasonController,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Observação (opcional)',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: approve ? Colors.green : wineColor),
            child: Text(approve ? 'LIBERAR' : 'RECUSAR',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final id = request['id'].toString();
    setState(() => _decidingId = id);
    try {
      await _apiService.decideScheduleApproval(
        id,
        approve: approve,
        reason: reasonController.text.trim(),
      );
      await _load(silent: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(approve ? 'Horário liberado.' : 'Solicitação recusada.'),
          backgroundColor: approve ? Colors.green : wineColor,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erro ao decidir: $e'),
          backgroundColor: wineColor,
        ));
      }
    } finally {
      if (mounted) setState(() => _decidingId = null);
      reasonController.dispose();
    }
  }

  Future<void> _openGlobalSettings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _GlobalScheduleDialog(),
    );
  }

  Color _statusColor(String status) {
    if (status == 'approved') return Colors.green;
    if (status == 'rejected') return wineColor;
    if (status == 'superseded') return Colors.grey;
    return Colors.orange.shade800;
  }

  // superseded: pedido de entrada antigo que o estagiario refez mais tarde
  // no mesmo dia (o backend fecha o antigo ao criar o novo).
  String _statusLabel(String status) {
    if (status == 'approved') return 'LIBERADA';
    if (status == 'rejected') return 'RECUSADA';
    if (status == 'superseded') return 'SUBSTITUIDA';
    return 'PENDENTE';
  }

  Widget _buildRequestCard(Map<String, dynamic> request) {
    final schedule = request['schedule_snapshot'] is Map
        ? Map<String, dynamic>.from(request['schedule_snapshot'] as Map)
        : <String, dynamic>{};
    final isStart = request['request_type'] == 'start_exception';
    final status = request['status']?.toString() ?? 'pending';
    final pending = status == 'pending';
    final deciding = _decidingId == request['id'].toString();
    final observation = request['notes']?.toString().trim() ?? '';
    final decisionReason = request['decision_reason']?.toString().trim() ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0x1A8B0000),
                  child: Icon(isStart ? Icons.login : Icons.more_time,
                      color: wineColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request['user_name']?.toString() ?? 'Estagiário',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(isStart
                          ? 'Entrada fora do horário'
                          : 'Continuar após o expediente'),
                      if ((request['user_email']?.toString() ?? '').isNotEmpty)
                        Text(
                          request['user_email'].toString(),
                          style:
                              const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusLabel(status),
                    style: TextStyle(
                      color: _statusColor(status),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Solicitado: ${_formatTimestamp(request['attempted_at'])}'),
            // Pedido anterior do mesmo dia que este substituiu: a chegada
            // real pode ter sido a dele (corrija pelo lote).
            if (request['previous_attempted_at'] != null)
              Text('Primeiro pedido do dia: '
                  '${_formatTimestamp(request['previous_attempted_at'])}'),
            Text(
                'Horário efetivo: ${schedule['shift_start'] ?? '-'} - ${schedule['shift_end'] ?? '-'}'),
            if (isStart)
              Text(
                  'Janela de entrada: ${schedule['start_allowed_from'] ?? '-'} - ${schedule['start_allowed_until'] ?? '-'}'),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blueGrey.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('OBSERVAÇÃO DO ESTAGIÁRIO',
                      style:
                          TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 5),
                  Text(observation.isEmpty
                      ? 'Pedido antigo sem observação.'
                      : observation),
                ],
              ),
            ),
            if (!pending) ...[
              const SizedBox(height: 12),
              const Divider(),
              Text('Decidido em: ${_formatTimestamp(request['decided_at'])}'),
              Text('Gestor: ${request['decided_by_name']?.toString() ?? '-'}'),
              if (decisionReason.isNotEmpty)
                Text('Observação do gestor: $decisionReason'),
            ],
            if (pending) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          deciding ? null : () => _decide(request, false),
                      child: const Text('RECUSAR'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: deciding ? null : () => _decide(request, true),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green),
                      child: deciding
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('LIBERAR',
                              style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: wineColor));
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: wineColor,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.isAdmin) ...[
            OutlinedButton.icon(
              onPressed: _openGlobalSettings,
              icon: const Icon(Icons.access_time),
              label: const Text('EDITAR HORÁRIO GLOBAL DOS ESTAGIÁRIOS'),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _changeView('pending'),
                  icon: const Icon(Icons.pending_actions),
                  label: const Text('PENDENTES'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _view == 'pending' ? wineColor : Colors.grey.shade200,
                    foregroundColor:
                        _view == 'pending' ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _changeView('history'),
                  icon: const Icon(Icons.storage_outlined),
                  label: const Text('HISTÓRICO'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _view == 'history' ? wineColor : Colors.grey.shade200,
                    foregroundColor:
                        _view == 'history' ? Colors.white : Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_view == 'history') ...[
            TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Buscar por estagiário, e-mail ou observação',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _historyStatus,
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('Todos')),
                DropdownMenuItem(value: 'approved', child: Text('Liberadas')),
                DropdownMenuItem(value: 'rejected', child: Text('Recusadas')),
              ],
              onChanged: (value) =>
                  setState(() => _historyStatus = value ?? 'all'),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            _view == 'pending'
                ? '${_visibleRequests.length} solicitação(ões) pendente(s)'
                : '${_visibleRequests.length} pedido(s) no histórico',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          if (_visibleRequests.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 50),
              child: Column(
                children: [
                  Icon(_view == 'pending' ? Icons.task_alt : Icons.storage,
                      size: 52, color: Colors.grey),
                  const SizedBox(height: 12),
                  Text(_view == 'pending'
                      ? 'Nenhuma liberação pendente.'
                      : 'Nenhum pedido encontrado no histórico.'),
                ],
              ),
            ),
          ..._visibleRequests.map(_buildRequestCard),
        ],
      ),
    );
  }
}

class _GlobalScheduleDialog extends StatefulWidget {
  const _GlobalScheduleDialog();

  @override
  State<_GlobalScheduleDialog> createState() => _GlobalScheduleDialogState();
}

class _GlobalScheduleDialogState extends State<_GlobalScheduleDialog> {
  final _apiService = ApiService();
  final Map<String, TextEditingController> _controllers = {};
  bool _loading = true;
  bool _saving = false;

  static const _fields = {
    'shift_start': 'Início do turno',
    'shift_end': 'Fim do turno',
    'start_allowed_from': 'Entrada permitida a partir de',
    'start_allowed_until': 'Entrada permitida até',
    'overtime_prompt_after': 'Bloquear tela após',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final schedule = await _apiService.getGlobalWorkSchedule();
      for (final field in _fields.keys) {
        _controllers[field] =
            TextEditingController(text: schedule[field]?.toString() ?? '');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erro: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _apiService.updateGlobalWorkSchedule({
        for (final field in _fields.keys)
          field: _controllers[field]!.text.trim(),
        'timezone': 'America/Sao_Paulo',
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erro ao salvar: $e'),
          backgroundColor: const Color(0xFF8B0000),
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Horário global dos estagiários'),
      content: _loading
          ? const SizedBox(
              height: 100, child: Center(child: CircularProgressIndicator()))
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Use o formato 24 horas: HH:mm.'),
                  const SizedBox(height: 12),
                  for (final entry in _fields.entries) ...[
                    TextField(
                      controller: _controllers[entry.key],
                      decoration: InputDecoration(labelText: entry.value),
                      keyboardType: TextInputType.datetime,
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _loading || _saving ? null : _save,
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

class _TeamStatusTab extends StatefulWidget {
  const _TeamStatusTab();

  @override
  State<_TeamStatusTab> createState() => _TeamStatusTabState();
}

class _TeamStatusTabState extends State<_TeamStatusTab> {
  final _apiService = ApiService();
  static const Color wineColor = Color(0xFF8B0000);

  bool _isLoading = true;
  List<Map<String, dynamic>> _summaries = [];
  String _statusFilter = 'all';
  String _roleFilter = 'all';
  bool _showInactive = false;
  Timer? _timer;

  // Pontos de ontem, para o turno que passou da meia-noite. Dia fechado quase
  // nao muda e o resumo atualiza a cada 5 min: le uma vez por dia (puxar a
  // lista para baixo le de novo). Estatico como o cache de usuarios: a aba e
  // recriada a cada troca de aba.
  static String? _yesterdayKey;
  static List<Map<String, dynamic>> _yesterdayRecords = const [];
  // Pontos de hoje que comecam o dia sem entrada e que a vespera lida nao
  // explica (dayStartWithoutShift): a vespera mudou depois de lida (lote do
  // gestor em outro aparelho, ponto offline). Cada um pede uma leitura nova,
  // uma vez so.
  static Set<String> _yesterdayCheckedStarts = const {};

  String _statusFilterLabel() {
    switch (_statusFilter) {
      case 'working':
        return 'Trabalhando';
      case 'paused':
        return 'Em pausa';
      case 'paused_overdue':
        return 'Pausa longa';
      case 'done':
        return 'Expediente encerrado';
      case 'none':
        return 'Sem ponto hoje';
      default:
        return 'Todos os status';
    }
  }

  bool _matchesStatusFilter(Map<String, dynamic> summary) {
    if (_statusFilter == 'all') return true;
    return summary['status_key'] == _statusFilter;
  }

  String _roleFilterLabel() {
    switch (_roleFilter) {
      case 'intern':
        return 'Somente estagiários';
      case 'aux_general':
        return 'Aux. Geral';
      case 'technical_general':
        return 'Técnico Geral';
      default:
        return 'Todos os cargos';
    }
  }

  bool _matchesRoleFilter(Map<String, dynamic> summary) {
    if (_roleFilter == 'all') return true;

    final role = (summary['role'] ?? '').toString().toLowerCase();
    final title = (summary['job_title'] ?? '').toString().toLowerCase();
    final normalizedTitle = title
        .replaceAll('á', 'a')
        .replaceAll('ã', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u');

    switch (_roleFilter) {
      case 'intern':
        return role == 'intern' ||
            role.contains('estag') ||
            normalizedTitle.contains('estag');
      case 'aux_general':
        return normalizedTitle.contains('aux') &&
            normalizedTitle.contains('geral');
      case 'technical_general':
        return normalizedTitle.contains('tecnico') &&
            normalizedTitle.contains('geral');
      default:
        return true;
    }
  }

  Widget _filterField({required String label, required Widget child}) {
    return Container(
      width: 220,
      height: 52,
      padding: const EdgeInsets.fromLTRB(12, 5, 10, 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFD8B5B1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF7A5B58))),
          const SizedBox(height: 1),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadSummary();
    // 5 min em vez de 1: cada ciclo le os usuarios + os pontos do dia. Quem
    // precisa do numero na hora puxa a lista para baixo (RefreshIndicator).
    _timer = Timer.periodic(
        const Duration(minutes: 5), (_) => _loadSummary(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadSummary(
      {bool silent = false, bool refreshYesterday = false}) async {
    if (!silent && mounted) setState(() => _isLoading = true);

    try {
      // Atualizacao automatica usa o cache; pull-to-refresh (silent == false)
      // pede dado novo.
      final users = await _apiService.getUsers(forceRefresh: !silent);
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day).toIso8601String();
      // Fim do dia com microssegundos: o backend grava 23:59:59.123456, que
      // na comparacao de texto fica depois de "23:59:59".
      final end = DateTime(now.year, now.month, now.day, 23, 59, 59, 999, 999)
          .toIso8601String();
      final records =
          await _apiService.getAdminTimeRecords(startDate: start, endDate: end);
      final recordsByUser = _groupByUser(records);
      final yesterday =
          await _loadYesterdayRecords(now, refreshYesterday, recordsByUser);
      final yesterdayByUser = _groupByUser(yesterday);

      final summaries = users.map<Map<String, dynamic>>((rawUser) {
        final user = Map<String, dynamic>.from(rawUser);
        final userId = user['id']?.toString();
        final todayRecords = recordsByUser[userId] ?? [];
        final shift = _currentShiftRecords(
            yesterdayByUser[userId] ?? const [], todayRecords, now);
        return _buildUserSummary(user, shift, now);
      }).toList();

      summaries.sort((a, b) {
        const priority = {
          'working': 0,
          'paused_overdue': 1,
          'paused': 2,
          'done': 3,
          'none': 4
        };
        final pA = priority[a['status_key']] ?? 9;
        final pB = priority[b['status_key']] ?? 9;
        if (pA != pB) return pA.compareTo(pB);
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      if (mounted) {
        setState(() {
          _summaries = summaries;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Erro resumo equipe: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _loadYesterdayRecords(DateTime now,
      bool force, Map<String, List<Map<String, dynamic>>> todayByUser) async {
    final day = DateTime(now.year, now.month, now.day - 1);
    final key = DateFormat('yyyy-MM-dd').format(day);
    if (!force &&
        _yesterdayKey == key &&
        _yesterdayCheckedStarts
            .containsAll(_startsWithoutShift(_yesterdayRecords, todayByUser))) {
      return _yesterdayRecords;
    }
    final records = await _apiService.getAdminTimeRecords(
      startDate: day.toIso8601String(),
      endDate: DateTime(day.year, day.month, day.day, 23, 59, 59, 999, 999)
          .toIso8601String(),
    );
    _yesterdayRecords =
        records.map((record) => Map<String, dynamic>.from(record)).toList();
    _yesterdayKey = key;
    // Os que nem a vespera nova explica nao pedem outra leitura.
    _yesterdayCheckedStarts =
        _startsWithoutShift(_yesterdayRecords, todayByUser);
    return _yesterdayRecords;
  }

  /// Pontos de hoje, um por usuario, que comecam o dia sem entrada e que
  /// [yesterday] nao explica (dayStartWithoutShift).
  Set<String> _startsWithoutShift(List<Map<String, dynamic>> yesterday,
      Map<String, List<Map<String, dynamic>>> todayByUser) {
    final yesterdayByUser = _groupByUser(yesterday);
    return {
      for (final MapEntry(key: userId, value: today) in todayByUser.entries)
        if (dayStartWithoutShift(yesterdayByUser[userId] ?? const [], today)
            case final start?)
          '$userId|${start['id'] ?? start['timestamp']}',
    };
  }

  /// Pontos por usuario, em ordem cronologica.
  Map<String, List<Map<String, dynamic>>> _groupByUser(
      Iterable<dynamic> records) {
    final byUser = <String, List<Map<String, dynamic>>>{};
    for (final rawRecord in records) {
      final record = Map<String, dynamic>.from(rawRecord);
      final userId = record['user_id']?.toString();
      if (userId == null) continue;
      byUser.putIfAbsent(userId, () => []).add(record);
    }
    for (final list in byUser.values) {
      // No mesmo horario, a ordem vem do tipo (sortRecords).
      sortRecords(list);
    }
    return byUser;
  }

  /// Pontos que o resumo considera: os de hoje e, quando o turno de ontem
  /// ainda estava aberto na meia-noite (entrada 19:30, saida 07:00), os de
  /// ontem desde a entrada. So com hoje, quem entrou 19:30 aparecia "Sem
  /// ponto hoje" as 02:00 e com 00h00 depois da saida das 07:00.
  /// Se hoje ja tem entrada, o turno de ontem acabou e o resumo segue o
  /// turno novo (os pontos da madrugada sao do turno de ontem). Sem ponto
  /// hoje ate [maxShiftSpan] depois da entrada e saida esquecida, nao turno.
  List<Map<String, dynamic>> _currentShiftRecords(
    List<Map<String, dynamic>> yesterday,
    List<Map<String, dynamic>> today,
    DateTime now,
  ) {
    final open = openShiftCheckIn(yesterday);
    final openAt = DateTime.tryParse(open?['timestamp']?.toString() ?? '');
    if (open == null || openAt == null) return today;
    final next = today.isEmpty
        ? now
        : DateTime.tryParse(today.first['timestamp'].toString()) ?? now;
    if (next.difference(openAt) > maxShiftSpan) return today;

    final firstCheckIn =
        today.indexWhere((record) => record['record_type'] == 'check_in');
    if (firstCheckIn >= 0) return today.sublist(firstCheckIn);
    final from = open['timestamp'].toString();
    return [
      ...yesterday.where(
          (record) => record['timestamp'].toString().compareTo(from) >= 0),
      ...today,
    ];
  }

  Map<String, dynamic> _buildUserSummary(
    Map<String, dynamic> user,
    List<Map<String, dynamic>> records,
    DateTime now,
  ) {
    Duration worked = Duration.zero;
    DateTime? workStart;
    var resumedByAutomaticEnd = false;

    for (final record in records) {
      final type = record['record_type']?.toString();
      final timestamp = DateTime.parse(record['timestamp']);

      if (type == 'check_in') {
        workStart ??= timestamp;
      } else if (type == 'break_end' || type == 'exit_3') {
        // Fim real depois do automatico na mesma pausa (ponto offline que
        // sincronizou tarde): vale o real, como na folha.
        final automatic = isAutomaticBreakEnd(record);
        if (workStart == null || (resumedByAutomaticEnd && !automatic)) {
          workStart = timestamp;
          resumedByAutomaticEnd = automatic;
        }
      } else if (type == 'break_start' ||
          type == 'entry_3' ||
          type == 'check_out') {
        if (workStart != null && timestamp.isAfter(workStart)) {
          worked += timestamp.difference(workStart);
        }
        workStart = null;
        resumedByAutomaticEnd = false;
      }
    }

    final lastRecord = records.isNotEmpty ? records.last : null;
    final lastType = lastRecord?['record_type']?.toString();
    final lastTime =
        lastRecord != null ? DateTime.parse(lastRecord['timestamp']).toLocal() : null;
    // Turno que comecou ontem: as horas sao do turno, nao so de hoje.
    final firstTime = records.isNotEmpty
        ? DateTime.parse(records.first['timestamp']).toLocal()
        : null;
    final fromYesterday = firstTime != null &&
        firstTime.isBefore(DateTime(now.year, now.month, now.day));

    String statusKey = 'none';
    String statusLabel = 'Sem ponto hoje';
    Color statusColor = Colors.grey;
    bool pauseOverdue = false;

    if (lastType == 'check_in' ||
        lastType == 'break_end' ||
        lastType == 'exit_3') {
      statusKey = 'working';
      statusLabel = 'Trabalhando agora';
      statusColor = Colors.green;
      if (workStart != null && now.isAfter(workStart)) {
        worked += now.difference(workStart);
      }
    } else if (lastType == 'break_start' || lastType == 'entry_3') {
      final pauseDuration =
          lastTime == null ? Duration.zero : now.difference(lastTime);
      pauseOverdue = pauseDuration.inMinutes >= 90;
      statusKey = pauseOverdue ? 'paused_overdue' : 'paused';
      statusLabel = pauseOverdue ? 'Pausa aberta ha mais de 1h30' : 'Em pausa';
      statusColor = pauseOverdue ? Colors.red : Colors.orange;
    } else if (lastType == 'check_out') {
      statusKey = 'done';
      statusLabel = 'Expediente encerrado';
      statusColor = wineColor;
    }

    return {
      'name': user['name']?.toString() ?? 'Sem nome',
      'role': user['role']?.toString() ?? '',
      'job_title': user['job_title']?.toString() ?? '',
      'status_key': statusKey,
      'status_label': statusLabel,
      'status_color': statusColor,
      'worked': worked,
      'last_time': lastTime,
      'from_yesterday': fromYesterday,
      'pause_overdue': pauseOverdue,
      'records_count': records.length,
    };
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    return '${hours.toString().padLeft(2, '0')}h${minutes.toString().padLeft(2, '0')}';
  }

  /// Hora do ultimo ponto, com a data quando ele e de ontem (turno que
  /// passou da meia-noite).
  String _formatLastTime(DateTime time) {
    final now = DateTime.now();
    final isToday =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return DateFormat(isToday ? 'HH:mm' : 'dd/MM HH:mm').format(time);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: wineColor));
    }

    final workingCount =
        _summaries.where((s) => s['status_key'] == 'working').length;
    final pausedCount = _summaries
        .where((s) =>
            s['status_key'] == 'paused' || s['status_key'] == 'paused_overdue')
        .length;
    final overdueCount =
        _summaries.where((s) => s['pause_overdue'] == true).length;
    final filteredSummaries = _summaries
        .where(_matchesStatusFilter)
        .where(_matchesRoleFilter)
        .toList();

    return RefreshIndicator(
      onRefresh: () => _loadSummary(refreshYesterday: true),
      color: wineColor,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        children: [
          Row(
            children: [
              _buildCounter('Trabalhando', workingCount, Colors.green),
              const SizedBox(width: 8),
              _buildCounter('Em pausa', pausedCount, Colors.orange),
              const SizedBox(width: 8),
              _buildCounter('Pausa longa', overdueCount, Colors.red),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PopupMenuButton<String>(
                constraints: const BoxConstraints(minWidth: 190, maxWidth: 240),
                menuPadding: const EdgeInsets.symmetric(vertical: 4),
                onSelected: (value) => setState(() => _statusFilter = value),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      height: 40, value: 'all', child: Text('Todos os status')),
                  PopupMenuItem(
                      height: 40, value: 'working', child: Text('Trabalhando')),
                  PopupMenuItem(
                      height: 40, value: 'paused', child: Text('Em pausa')),
                  PopupMenuItem(
                      height: 40,
                      value: 'paused_overdue',
                      child: Text('Pausa longa')),
                  PopupMenuItem(
                      height: 40,
                      value: 'done',
                      child: Text('Expediente encerrado')),
                  PopupMenuItem(
                      height: 40, value: 'none', child: Text('Sem ponto hoje')),
                ],
                child: _filterField(
                  label: 'Status',
                  child: Row(
                    children: [
                      Expanded(child: Text(_statusFilterLabel())),
                      const Icon(Icons.keyboard_arrow_down, size: 18),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                constraints: const BoxConstraints(minWidth: 190, maxWidth: 240),
                menuPadding: const EdgeInsets.symmetric(vertical: 4),
                onSelected: (value) => setState(() => _roleFilter = value),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      height: 40, value: 'all', child: Text('Todos os cargos')),
                  PopupMenuItem(
                      height: 40,
                      value: 'intern',
                      child: Text('Somente estagiários')),
                  PopupMenuItem(
                      height: 40,
                      value: 'aux_general',
                      child: Text('Aux. Geral')),
                  PopupMenuItem(
                      height: 40,
                      value: 'technical_general',
                      child: Text('Técnico Geral')),
                ],
                child: _filterField(
                  label: 'Cargo',
                  child: Row(
                    children: [
                      Expanded(child: Text(_roleFilterLabel())),
                      const Icon(Icons.keyboard_arrow_down, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ..._buildTeamSection(filteredSummaries),
        ],
      ),
    );
  }

  /// Secao "foco nos ativos": cartoes so para quem esta trabalhando ou em
  /// pausa; inativos ficam recolhidos numa linha que expande no toque.
  List<Widget> _buildTeamSection(List<Map<String, dynamic>> summaries) {
    const activeKeys = {'working', 'paused', 'paused_overdue'};
    final active =
        summaries.where((s) => activeKeys.contains(s['status_key'])).toList();
    final inactive =
        summaries.where((s) => !activeKeys.contains(s['status_key'])).toList();

    // Se o filtro de status aponta para inativos, mostra-os sem recolher.
    final forceInactive = _statusFilter == 'done' || _statusFilter == 'none';
    final doneCount =
        inactive.where((s) => s['status_key'] == 'done').length;
    final noneCount =
        inactive.where((s) => s['status_key'] == 'none').length;

    final parts = <String>[
      if (doneCount > 0) '$doneCount ${doneCount == 1 ? 'encerrado' : 'encerrados'}',
      if (noneCount > 0) '$noneCount sem ponto hoje',
    ];

    return [
      const Text(
        'ATIVOS AGORA',
        style: TextStyle(
            color: Colors.grey,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.1),
      ),
      const SizedBox(height: 12),
      if (active.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 22),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
          ),
          child: const Column(
            children: [
              Icon(Icons.bedtime_outlined, color: Colors.grey, size: 26),
              SizedBox(height: 6),
              Text('Ninguém batendo ponto agora',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            ],
          ),
        )
      else
        SizedBox(
          height: 188,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: active.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) =>
                _buildEmployeeStatusCard(active[index]),
          ),
        ),
      if (inactive.isNotEmpty) ...[
        const SizedBox(height: 16),
        if (!forceInactive)
          InkWell(
            onTap: () => setState(() => _showInactive = !_showInactive),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    _showInactive ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    parts.join(' · '),
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        if (forceInactive || _showInactive)
          ...inactive.map(_buildCompactInactiveRow),
      ],
    ];
  }

  Widget _buildCompactInactiveRow(Map<String, dynamic> summary) {
    final color = summary['status_color'] as Color;
    final lastTime = summary['last_time'] as DateTime?;
    final worked = summary['worked'] as Duration;
    final isDone = summary['status_key'] == 'done';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              summary['name'],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          Text(
            summary['status_label'],
            style: TextStyle(color: color, fontSize: 12),
          ),
          if (isDone) ...[
            const SizedBox(width: 12),
            Text(
              _formatDuration(worked),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ],
          if (lastTime != null) ...[
            const SizedBox(width: 12),
            Text(
              _formatLastTime(lastTime),
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCounter(String label, int value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$value',
                style: TextStyle(
                    color: color, fontSize: 22, fontWeight: FontWeight.bold)),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmployeeStatusCard(Map<String, dynamic> summary) {
    final color = summary['status_color'] as Color;
    final lastTime = summary['last_time'] as DateTime?;
    final worked = summary['worked'] as Duration;

    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: color,
                child: Text(
                  (summary['name'] as String).isNotEmpty
                      ? (summary['name'] as String)[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  summary['name'],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(summary['status_label'],
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(
              summary['from_yesterday'] == true
                  ? 'Horas do turno'
                  : 'Horas hoje',
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
          Text(_formatDuration(worked),
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            lastTime == null
                ? 'Sem registros hoje'
                : 'Ultimo ponto ${_formatLastTime(lastTime)}',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
        ],
      ),
    );
  }

}

class UserEditDialog extends StatefulWidget {
  final dynamic user;
  final VoidCallback onSave;

  const UserEditDialog({super.key, required this.user, required this.onSave});

  @override
  State<UserEditDialog> createState() => _UserEditDialogState();
}

class _UserEditDialogState extends State<UserEditDialog> {
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _cpfController;
  late TextEditingController _passwordController;
  late TextEditingController _hoursController;
  late TextEditingController _jobTitleController;
  final Map<String, TextEditingController> _scheduleControllers = {};
  late String _selectedRole;
  bool _disabled = false;
  bool _scheduleOverrideEnabled = false;
  // Modo diaria: so para Funcionario.
  bool _dailyMode = false;
  bool _obscurePassword = true;
  // "Voltar para a senha padrao": ao salvar, a conta volta para a 123456.
  bool _resetPassword = false;
  final _apiService = ApiService();
  bool _isSaving = false;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.user['name']?.toString() ?? '');
    _emailController =
        TextEditingController(text: widget.user['email']?.toString() ?? '');
    final savedCpf = widget.user['cpf']?.toString() ?? '';
    _cpfController = TextEditingController(
        text: cpfDigits(savedCpf).length == 11 ? formatCpf(savedCpf) : savedCpf);
    _passwordController = TextEditingController();
    _hoursController =
        TextEditingController(text: widget.user['daily_hours'].toString());
    final savedRole = widget.user['role']?.toString() ?? 'employee';
    _selectedRole = savedRole == 'estagiario' ? 'intern' : savedRole;
    _jobTitleController = TextEditingController(
      text: _initialJobTitle(_selectedRole, widget.user['job_title']),
    );
    _disabled = widget.user['disabled'] == true;
    _dailyMode = widget.user['daily_mode'] == true;
    _scheduleOverrideEnabled =
        widget.user['work_schedule_override_enabled'] == true;
    final rawOverride = widget.user['work_schedule_override'];
    final override = rawOverride is Map
        ? Map<String, dynamic>.from(rawOverride)
        : <String, dynamic>{};
    const defaults = {
      'shift_start': '13:30',
      'shift_end': '19:30',
      'start_allowed_from': '13:25',
      'start_allowed_until': '19:25',
      'overtime_prompt_after': '19:35',
    };
    for (final entry in defaults.entries) {
      _scheduleControllers[entry.key] = TextEditingController(
          text: override[entry.key]?.toString() ?? entry.value);
    }
  }

  String _initialJobTitle(String role, dynamic savedTitle) {
    if (role == 'intern') return 'Estagiario';
    final title = savedTitle?.toString().trim();
    if (title != null && title.isNotEmpty) return title;
    return 'Aux. Geral';
  }

  Widget _scheduleField(String key, String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextFormField(
        controller: _scheduleControllers[key],
        decoration: InputDecoration(
          labelText: label,
          helperText: 'Formato HH:mm',
        ),
        keyboardType: TextInputType.datetime,
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _cpfController.dispose();
    _passwordController.dispose();
    _hoursController.dispose();
    _jobTitleController.dispose();
    for (final controller in _scheduleControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Editar: ${widget.user['name']}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                  labelText: 'Nome cadastrado',
                  labelStyle: TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _cpfController,
              decoration: const InputDecoration(
                  labelText: 'CPF', helperText: 'É o login da pessoa.'),
              keyboardType: TextInputType.number,
              inputFormatters: [CpfInputFormatter()],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _emailController,
              decoration: const InputDecoration(
                  labelText: 'E-mail (opcional)',
                  helperText: 'Sem e-mail, o acesso é só pelo CPF.'),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              enabled: !_resetPassword,
              decoration: InputDecoration(
                labelText: 'Nova senha',
                helperText: 'Deixe vazio para manter. Com senha nova, a pessoa '
                    'cria a própria no próximo acesso.',
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  icon: Icon(_obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _resetPassword = !_resetPassword;
                  if (_resetPassword) _passwordController.clear();
                }),
                icon: Icon(_resetPassword ? Icons.check_box : Icons.lock_reset,
                    size: 18),
                label: Text(_resetPassword
                    ? 'Volta para a senha padrão (123456) ao salvar'
                    : 'Voltar para a senha padrão (123456)'),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _disabled,
              onChanged: (value) => setState(() => _disabled = value),
              title: const Text('Conta desativada'),
              subtitle: const Text('Impede o usuário de entrar no sistema.'),
            ),
            const Divider(height: 28),
            DropdownButtonFormField<String>(
              initialValue: _selectedRole,
              dropdownColor: Theme.of(context).cardColor,
              decoration: const InputDecoration(
                  labelText: 'Cargo/Modelo',
                  labelStyle: TextStyle(color: Colors.grey)),
              items: const [
                DropdownMenuItem(
                    value: 'employee', child: Text('Funcionário (8h)')),
                DropdownMenuItem(
                    value: 'intern', child: Text('Estagiário (6h)')),
                DropdownMenuItem(value: 'manager', child: Text('Gestor')),
                DropdownMenuItem(value: 'admin', child: Text('Administrador')),
              ],
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedRole = val;
                    if (val == 'intern') {
                      _hoursController.text = '6.0';
                      _jobTitleController.text = 'Estagiario';
                    }
                    if (val == 'employee') {
                      _hoursController.text = '8.0';
                      if (_jobTitleController.text.trim().isEmpty ||
                          _jobTitleController.text.trim() == 'Estagiario') {
                        _jobTitleController.text = 'Aux. Geral';
                      }
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _jobTitleController,
              decoration: const InputDecoration(
                labelText: 'Função na folha',
                helperText: 'Ex: Estagiário, Aux. Geral, Coordenador de Campo',
                labelStyle: TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _hoursController,
              decoration: const InputDecoration(
                  labelText: 'Carga Horária Diária',
                  labelStyle: TextStyle(color: Colors.grey)),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            if (_selectedRole == 'employee') ...[
              const Divider(height: 32),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _dailyMode,
                onChanged: (value) => setState(() => _dailyMode = value),
                title: const Text('Modo diária'),
                subtitle: const Text(
                    'A tela de ponto vira só o botão "Adicionar diária" (uma '
                    'por dia). A exportação traz as diárias e uma folha de '
                    'ponto padrão com a carga diária acima.'),
              ),
            ],
            if (_selectedRole == 'intern' || _selectedRole == 'estagiario') ...[
              const Divider(height: 32),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _scheduleOverrideEnabled,
                onChanged: (value) =>
                    setState(() => _scheduleOverrideEnabled = value),
                title: const Text('Horário individual'),
                subtitle: const Text(
                    'Quando desligado, usa o horário global dos estagiários.'),
              ),
              if (_scheduleOverrideEnabled) ...[
                _scheduleField('shift_start', 'Início do turno'),
                _scheduleField('shift_end', 'Fim do turno'),
                _scheduleField(
                    'start_allowed_from', 'Entrada permitida a partir de'),
                _scheduleField('start_allowed_until', 'Entrada permitida até'),
                _scheduleField('overtime_prompt_after', 'Bloquear tela após'),
              ],
            ],
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: (_isSaving || _isDeleting) ? null : _confirmDelete,
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          label: const Text('Excluir', style: TextStyle(color: Colors.red)),
        ),
        const SizedBox(width: 12),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.grey))),
        ElevatedButton(
          onPressed: _isSaving ? null : _save,
          style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B0000)),
          child: _isSaving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Text('Salvar', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final cpf = _cpfController.text.trim();
    // E-mail opcional; sem ele, o CPF e o login e precisa ser valido.
    final String? problem = name.isEmpty
        ? 'Informe o nome.'
        : (email.isNotEmpty && !email.contains('@'))
            ? 'E-mail inválido.'
            : (email.isEmpty && cpfDigits(cpf).length != 11)
                ? 'Sem e-mail, informe um CPF válido: ele é o login.'
                : null;
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(problem),
            backgroundColor: const Color(0xFF8B0000)),
      );
      return;
    }
    if (password.isNotEmpty && password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('A nova senha deve ter pelo menos 6 caracteres.'),
            backgroundColor: Color(0xFF8B0000)),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result = await _apiService.updateUserAdmin(
        widget.user['id'],
        name: name,
        email: email,
        role: _selectedRole,
        jobTitle: _jobTitleController.text.trim().isEmpty
            ? (_selectedRole == 'intern' ? 'Estagiario' : 'Aux. Geral')
            : _jobTitleController.text.trim(),
        dailyHours: double.tryParse(_hoursController.text) ?? 8.0,
        cpf: _cpfController.text.trim(),
        disabled: _disabled,
        newPassword: password.isEmpty || _resetPassword ? null : password,
        resetPassword: _resetPassword,
        workScheduleOverrideEnabled: _scheduleOverrideEnabled,
        workScheduleOverride: _scheduleOverrideEnabled
            ? {
                for (final entry in _scheduleControllers.entries)
                  entry.key: entry.value.text.trim(),
                'timezone': 'America/Sao_Paulo',
              }
            : null,
        dailyMode: _selectedRole == 'employee' && _dailyMode,
      );
      widget.onSave();
      final temporary = result['temporary_password']?.toString();
      if (temporary != null && temporary.isNotEmpty && mounted) {
        await showDialog(
          context: context,
          builder: (context) => AccessMessageDialog(
            name: name,
            cpf: _cpfController.text.trim(),
            password: temporary,
            title: 'Senha padrão definida',
          ),
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Erro: $e'),
              backgroundColor: const Color(0xFF8B0000)),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final confirmController = TextEditingController();
    final userName = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : widget.user['name']?.toString() ?? '';
    String? errorText;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Excluir conta'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Isso removera "$userName" da lista de usuarios.'),
                  const SizedBox(height: 8),
                  const Text(
                    'Os registros de ponto antigos serao preservados para historico.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Text('Digite o nome para confirmar: $userName'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmController,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      errorText: errorText,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (confirmController.text.trim() != userName) {
                      setDialogState(() => errorText =
                          'Nome diferente. Confira e tente novamente.');
                      return;
                    }
                    Navigator.pop(dialogContext, true);
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('Excluir conta',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );

    confirmController.dispose();
    if (confirmed != true) return;

    setState(() => _isDeleting = true);
    try {
      await _apiService.deleteUserAdmin(widget.user['id']);
      widget.onSave();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Conta excluida da lista de usuarios.'),
            backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Erro ao excluir conta: $e'),
            backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }
}

/// Cadastro de uma pessoa pelo admin (nao ha mais cadastro pelo app). Ela
/// entra com o CPF e a senha padrao (123456) e cria a propria
/// no primeiro acesso.
/// Devolve {'name', 'cpf'} da conta criada, ou null.
class UserCreateDialog extends StatefulWidget {
  const UserCreateDialog({super.key});

  @override
  State<UserCreateDialog> createState() => _UserCreateDialogState();
}

class _UserCreateDialogState extends State<UserCreateDialog> {
  static const Color wineColor = Color(0xFF8B0000);

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _cpfController = TextEditingController();
  final _emailController = TextEditingController();
  final _jobTitleController = TextEditingController(text: 'Aux. Geral');
  final _hoursController = TextEditingController(text: '8.0');
  final _apiService = ApiService();
  String _role = 'employee';
  bool _dailyMode = false;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _cpfController.dispose();
    _emailController.dispose();
    _jobTitleController.dispose();
    _hoursController.dispose();
    super.dispose();
  }

  void _changeRole(String role) {
    setState(() {
      _role = role;
      if (role == 'intern') {
        _hoursController.text = '6.0';
        _jobTitleController.text = 'Estagiario';
      } else if (role == 'employee') {
        _hoursController.text = '8.0';
        if (_jobTitleController.text.trim().isEmpty ||
            _jobTitleController.text.trim() == 'Estagiario') {
          _jobTitleController.text = 'Aux. Geral';
        }
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final name = _nameController.text.trim();
      final created = await _apiService.createUserAdmin(
        name: name,
        cpf: _cpfController.text,
        email: _emailController.text.trim(),
        role: _role,
        jobTitle: _jobTitleController.text.trim().isEmpty
            ? (_role == 'intern' ? 'Estagiario' : 'Aux. Geral')
            : _jobTitleController.text.trim(),
        dailyHours: double.tryParse(
                _hoursController.text.replaceAll(',', '.')) ??
            (_role == 'intern' ? 6.0 : 8.0),
        dailyMode: _role == 'employee' && _dailyMode,
      );
      if (!mounted) return;
      Navigator.pop(context, {
        'name': name,
        'cpf': created['cpf']?.toString() ?? formatCpf(_cpfController.text),
        'password': (created['temporary_password'] ??
                created['default_password'] ??
                '')
            .toString(),
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Erro ao cadastrar: ${e.toString().replaceAll('Exception:', '').trim()}'),
        backgroundColor: wineColor,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Novo usuário'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: wineColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'A pessoa entra com o CPF e a senha padrão 123456. No '
                  'primeiro acesso, o app pede para ela criar a própria senha.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nome completo'),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Informe o nome.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _cpfController,
                keyboardType: TextInputType.number,
                inputFormatters: [CpfInputFormatter()],
                decoration: const InputDecoration(
                    labelText: 'CPF', helperText: 'É o login da pessoa.'),
                validator: (value) =>
                    isValidCpf(value) ? null : 'CPF inválido.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                    labelText: 'E-mail (opcional)',
                    helperText: 'Com e-mail, ela também pode recuperar a senha '
                        'por ele.',
                    helperMaxLines: 2),
                validator: (value) {
                  final text = (value ?? '').trim();
                  return text.isNotEmpty && !text.contains('@')
                      ? 'E-mail inválido.'
                      : null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Cargo/Modelo'),
                items: const [
                  DropdownMenuItem(
                      value: 'employee', child: Text('Funcionário (8h)')),
                  DropdownMenuItem(
                      value: 'intern', child: Text('Estagiário (6h)')),
                  DropdownMenuItem(value: 'manager', child: Text('Gestor')),
                  DropdownMenuItem(value: 'admin', child: Text('Administrador')),
                ],
                onChanged: (value) {
                  if (value != null) _changeRole(value);
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _jobTitleController,
                decoration: const InputDecoration(
                    labelText: 'Função na folha',
                    helperText: 'Ex: Aux. Geral, Coordenador de Campo'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _hoursController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Carga Horária Diária'),
              ),
              if (_role == 'employee')
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _dailyMode,
                  onChanged: (value) => setState(() => _dailyMode = value),
                  title: const Text('Modo diária'),
                  subtitle: const Text(
                      'A tela de ponto vira só o botão "Adicionar diária".'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(backgroundColor: wineColor),
          child: _saving
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : const Text('Cadastrar', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

/// Depois do cadastro: a mensagem com o acesso para mandar a pessoa
/// (copiar ou abrir no WhatsApp).
class AccessMessageDialog extends StatelessWidget {
  const AccessMessageDialog({
    super.key,
    required this.name,
    required this.cpf,
    required this.password,
    this.title = 'Usuário cadastrado',
  });

  final String name;
  final String cpf;

  /// Senha do primeiro acesso (a padrao, 123456).
  final String password;
  final String title;

  static const Color wineColor = Color(0xFF8B0000);

  String get _message {
    final firstName = name.trim().split(RegExp(r'\s+')).first;
    return [
      'Olá, $firstName! Seu acesso ao Ponto VMac:',
      // O endereco que o admin esta usando e o do app.
      'Endereço: ${Uri.base.origin}',
      'Login (CPF): $cpf',
      'Senha do primeiro acesso: $password',
      'No primeiro acesso o app pede para você criar uma senha nova.',
    ].join('\n');
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _message));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Mensagem copiada.'),
      backgroundColor: Colors.green,
    ));
  }

  Future<void> _whatsApp(BuildContext context) async {
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(_message)}');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Não deu para abrir o WhatsApp. Use "Copiar".'),
        backgroundColor: wineColor,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Mande o acesso para a pessoa:'),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(_message,
                style: const TextStyle(fontSize: 13, height: 1.4)),
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => _copy(context),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copiar'),
        ),
        TextButton.icon(
          onPressed: () => _whatsApp(context),
          icon: const Icon(Icons.send, size: 18),
          label: const Text('WhatsApp'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context),
          style: ElevatedButton.styleFrom(backgroundColor: wineColor),
          child: const Text('OK', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _ManualEntryTab extends StatefulWidget {
  const _ManualEntryTab();

  @override
  State<_ManualEntryTab> createState() => _ManualEntryTabState();
}

class _ManualEntryTabState extends State<_ManualEntryTab> {
  final _apiService = ApiService();
  final _notesController = TextEditingController();

  List<dynamic> _users = [];
  dynamic _selectedUserId;
  DateTime _selectedDate = DateTime.now();

  TimeOfDay? _entryTime;
  TimeOfDay? _break1Start;
  TimeOfDay? _break1End;
  TimeOfDay? _break2Start;
  TimeOfDay? _break2End;
  TimeOfDay? _exitTime;

  bool _isLoadingUsers = true;
  bool _isSaving = false;

  static const Color wineColor = Color(0xFF8B0000);

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  Future<void> _fetchUsers({bool forceRefresh = false}) async {
    try {
      final users = await _apiService.getUsers(forceRefresh: forceRefresh);
      setState(() {
        _users = users;
        _isLoadingUsers = false;
      });
    } catch (e) {
      _showError('Erro ao carregar usuários: $e');
    }
  }

  Future<void> _selectDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2023),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context)
              .colorScheme
              .copyWith(primary: const Color(0xFF8B0000)),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay? initial) async {
    return await showTimePicker(
      context: context,
      initialTime: initial ?? const TimeOfDay(hour: 8, minute: 0),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(context)
                  .colorScheme
                  .copyWith(primary: const Color(0xFF8B0000)),
            ),
            child: child!,
          ),
        );
      },
    );
  }

  static const Map<String, String> _batchLabels = {
    'check_in': 'Entrada',
    'break_start': 'Pausa 1 (início)',
    'break_end': 'Pausa 1 (fim)',
    'entry_3': 'Pausa 2 (início)',
    'exit_3': 'Pausa 2 (fim)',
    'check_out': 'Saída',
  };

  /// Pede a confirmacao dos horarios que vao para o dia seguinte.
  Future<bool> _confirmNextDay(List<BatchPunch> nextDay) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Horários no dia seguinte'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final punch in nextDay)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('${_batchLabels[punch.recordType]} '
                    '${DateFormat('HH:mm').format(punch.at)} será lançada em '
                    '${DateFormat('dd/MM').format(punch.at)} (dia seguinte).'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(backgroundColor: wineColor),
            child: const Text('Lançar',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _saveBatch() async {
    if (_selectedUserId == null) {
      _showError('Selecione um funcionário');
      return;
    }

    final Map<String, TimeOfDay?> mappings = {
      'check_in': _entryTime,
      'break_start': _break1Start,
      'break_end': _break1End,
      'entry_3': _break2Start,
      'exit_3': _break2End,
      'check_out': _exitTime,
    };
    // Data real de cada ponto: com entrada, o que vem antes dela e do dia
    // seguinte (batch_entry.dart).
    final punches = planBatchPunches(_selectedDate, {
      for (final entry in mappings.entries)
        if (entry.value != null)
          entry.key: (hour: entry.value!.hour, minute: entry.value!.minute),
    });
    if (punches.isEmpty) {
      _showError('Preencha pelo menos um horário');
      return;
    }
    if (batchTooLong(punches)) {
      final span = batchShiftSpan(punches)!;
      _showError('Do primeiro ao último horário são ${span.inHours}h'
          '${(span.inMinutes % 60).toString().padLeft(2, '0')}, mais que '
          '${maxShiftSpan.inHours}h. Confira os horários (o que vem antes '
          'da entrada, ou do primeiro horário sem entrada, vai para o dia '
          'seguinte; saída igual à entrada também).');
      return;
    }
    final nextDay = punches.where((punch) => punch.nextDay).toList();
    if (nextDay.isNotEmpty && !await _confirmNextDay(nextDay)) return;
    if (!mounted) return;

    setState(() => _isSaving = true);
    try {
      int count = 0;
      for (final punch in punches) {
        await _apiService.createTimeRecord(
          recordType: punch.recordType,
          userId: _selectedUserId,
          timestamp: punch.at.toIso8601String(),
          notes: _notesController.text,
          location: 'Manual (Lote Gestor)',
          // Marca o ponto com a data real: as regras da noite do lote antigo
          // (saida antes da entrada na mesma data) nao valem para ele.
          extraFields: batchRecordFields,
        );
        count++;
      }

      _showSuccess('$count registros adicionados com sucesso!');
      _clearForm();
    } catch (e) {
      _showError('Erro ao salvar: $e\nVerifique as permissões do Firebase.');
    } finally {
      // Lote com ponto antes de hoje mudou a vespera que o Status da equipe
      // guarda o dia todo: a noite de ontem lancada agora grava a madrugada
      // em hoje, e sem a entrada de ontem essas horas iam para hoje.
      final today = DateTime.now();
      if (punches.any((punch) => punch.at
          .isBefore(DateTime(today.year, today.month, today.day)))) {
        _TeamStatusTabState._yesterdayKey = null;
      }
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _clearForm() {
    setState(() {
      _entryTime = _break1Start =
          _break1End = _break2Start = _break2End = _exitTime = null;
      _notesController.clear();
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: wineColor));
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.green));
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingUsers) {
      return const Center(child: CircularProgressIndicator(color: wineColor));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('LANÇAMENTO EM LOTE (DIA CHEIO)',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  color: Colors.grey)),
          const SizedBox(height: 24),
          DropdownButtonFormField<dynamic>(
            initialValue: _selectedUserId,
            dropdownColor: Theme.of(context).cardColor,
            decoration: const InputDecoration(
                labelText: 'Funcionário',
                labelStyle: TextStyle(color: Colors.grey),
                border: OutlineInputBorder()),
            items: _users
                .map((u) =>
                    DropdownMenuItem(value: u['id'], child: Text(u['name'])))
                .toList(),
            onChanged: (val) => setState(() => _selectedUserId = val),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _selectDate,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, color: wineColor),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Data do Registro',
                          style: TextStyle(color: Colors.grey, fontSize: 10)),
                      Text(DateFormat('dd/MM/yyyy').format(_selectedDate),
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text('HORÁRIOS DO DIA',
              style: TextStyle(
                  color: Colors.grey,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _buildTimeRow(
              '1. Entrada', _entryTime, (t) => setState(() => _entryTime = t)),
          _buildTimeRow('2. Pausa 1 (Início)', _break1Start,
              (t) => setState(() => _break1Start = t)),
          _buildTimeRow('3. Pausa 1 (Fim)', _break1End,
              (t) => setState(() => _break1End = t)),
          _buildTimeRow('4. Pausa 2 (Início)', _break2Start,
              (t) => setState(() => _break2Start = t)),
          _buildTimeRow('5. Pausa 2 (Fim)', _break2End,
              (t) => setState(() => _break2End = t)),
          _buildTimeRow(
              '6. Saída', _exitTime, (t) => setState(() => _exitTime = t)),
          const SizedBox(height: 4),
          const Text('Saída ou pausa antes da entrada vai para o dia seguinte.',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 24),
          TextField(
            controller: _notesController,
            decoration: const InputDecoration(
              labelText: 'Observação do Gestor',
              labelStyle: TextStyle(color: Colors.grey),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _isSaving ? null : _saveBatch,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B0000),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(double.infinity, 50),
            ),
            child: _isSaving
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Text('LANÇAR DIA INTEIRO',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
          ),
          const SizedBox(height: 50),
        ],
      ),
    );
  }

  Widget _buildTimeRow(
      String label, TimeOfDay? time, Function(TimeOfDay?) onPick) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () async {
          final t = await _pickTime(time);
          if (t != null) onPick(t);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.grey, fontSize: 13)),
              Row(
                children: [
                  Text(time?.format(context) ?? '--:--',
                      style: TextStyle(
                          color: time != null ? null : Colors.grey,
                          fontWeight: FontWeight.bold)),
                  if (time != null)
                    IconButton(
                      icon:
                          const Icon(Icons.close, size: 16, color: Colors.grey),
                      onPressed: () => onPick(null),
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.only(left: 8),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
