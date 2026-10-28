import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../services/web_pdf_picker.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  static const wineColor = Color(0xFF8B0000);
  static const _documentActionButtonSize = Size(190, 42);
  final _apiService = ApiService();
  List<Map<String, dynamic>> _documents = [];
  bool _isAdmin = false;
  bool _loading = true;
  bool _downloadingMonth = false;
  String _query = '';
  String _statusFilter = 'all';
  String _personFilter = 'all';
  DateTime? _monthFilter;

  Widget _documentActionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
  }) {
    return SizedBox.fromSize(
      size: _documentActionButtonSize,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, textAlign: TextAlign.center),
        style: OutlinedButton.styleFrom(
          foregroundColor: wineColor,
          side: const BorderSide(color: Color(0xFFB9A9A9)),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(22)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final user = await _apiService.getCurrentUser();
      final isAdmin = user['role'] == 'admin' || user['role'] == 'manager';
      final documents = await _apiService.getSignatureDocuments(admin: isAdmin);
      if (mounted) {
        setState(() {
          _isAdmin = isAdmin;
          _documents = documents;
        });
        final pendingDocuments = documents
            .where((document) => document['status']?.toString() == 'pending')
            .toList();
        if (!isAdmin && pendingDocuments.isNotEmpty) {
          unawaited(NotificationService.showSignatureRequest(
            pendingCount: pendingDocuments.length,
            title: pendingDocuments.first['title']?.toString() ?? 'Documento',
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao carregar documentos: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshDocument(Map<String, dynamic> document) async {
    try {
      await _apiService.refreshSignatureDocument(document['id'].toString());
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao atualizar documento: $e')),
        );
      }
    }
  }

  Future<void> _deleteDocument(Map<String, dynamic> document) async {
    final title = document['title']?.toString() ?? 'Documento';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apagar documento'),
        content: Text('Deseja apagar "$title" da lista de documentos?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: wineColor),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _apiService.deleteSignatureDocument(document['id'].toString());
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Documento apagado.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao apagar documento: $e')),
        );
      }
    }
  }

  Future<void> _openUrl(String? value) async {
    if (value == null || value.isEmpty) return;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nao foi possivel abrir o link.')),
        );
      }
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'signed':
        return 'Assinado';
      case 'pending':
        return 'Aguardando assinatura';
      case 'error':
        return 'Erro no envio';
      case 'creating':
        return 'Enviando';
      default:
        return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'signed':
        return Colors.green;
      case 'error':
        return Colors.red;
      case 'pending':
        return Colors.orange;
      default:
        return Colors.blueGrey;
    }
  }

  Future<void> _pickMonth() async {
    final selected = await showDialog<DateTime>(
      context: context,
      builder: (context) {
        final year = DateTime.now().year;
        const months = [
          'Jan',
          'Fev',
          'Mar',
          'Abr',
          'Mai',
          'Jun',
          'Jul',
          'Ago',
          'Set',
          'Out',
          'Nov',
          'Dez'
        ];
        return AlertDialog(
          title: Text('Escolha o mês de $year'),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(
                12,
                (index) => ChoiceChip(
                      label: Text(months[index]),
                      selected: _monthFilter?.year == year &&
                          _monthFilter?.month == index + 1,
                      onSelected: (_) =>
                          Navigator.pop(context, DateTime(year, index + 1)),
                    )),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            TextButton(
                onPressed: () => Navigator.pop(context, DateTime(0)),
                child: const Text('Todos')),
          ],
        );
      },
    );
    if (selected != null && mounted) {
      setState(() {
        _monthFilter = selected.year == 0 ? null : selected;
      });
    }
  }

  Future<DateTime?> _pickDownloadMonth() async {
    return showDialog<DateTime>(
      context: context,
      builder: (context) {
        final year = DateTime.now().year;
        const months = [
          'Jan',
          'Fev',
          'Mar',
          'Abr',
          'Mai',
          'Jun',
          'Jul',
          'Ago',
          'Set',
          'Out',
          'Nov',
          'Dez'
        ];
        return AlertDialog(
          title: const Text('Escolha o mes para baixar'),
          content: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(
              12,
              (index) => ChoiceChip(
                label: Text(months[index]),
                selected: false,
                onSelected: (_) =>
                    Navigator.pop(context, DateTime(year, index + 1)),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
          ],
        );
      },
    );
  }

  String _safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();
    return cleaned.isEmpty ? 'documento' : cleaned;
  }

  Future<void> _downloadMonthDocuments() async {
    final selectedMonth = await _pickDownloadMonth();
    if (selectedMonth == null) return;

    final documents = _documents.where((document) {
      final status = document['status']?.toString() ?? '';
      final signedUrl = document['signed_file_url']?.toString() ?? '';
      if (status != 'signed' || signedUrl.isEmpty) return false;

      final createdAt = DateTime.tryParse(
        document['created_at']?.toString() ?? '',
      )?.toLocal();
      return createdAt != null &&
          createdAt.year == selectedMonth.year &&
          createdAt.month == selectedMonth.month;
    }).toList();

    if (documents.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Nenhum PDF assinado encontrado nesse mes.')),
        );
      }
      return;
    }

    setState(() => _downloadingMonth = true);
    try {
      final archive = Archive();
      for (var index = 0; index < documents.length; index++) {
        final document = documents[index];
        final url = document['signed_file_url']?.toString() ?? '';
        final response =
            await http.get(Uri.parse(url)).timeout(const Duration(seconds: 40));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception(
              'Falha ao baixar ${document['title'] ?? 'documento'} (${response.statusCode}).');
        }

        final title = _safeFileName(
          document['title']?.toString() ?? 'documento_${index + 1}',
        );
        final userName = _safeFileName(
          document['user_name']?.toString() ?? 'colaborador',
        );
        archive.addFile(
          ArchiveFile(
            '${(index + 1).toString().padLeft(2, '0')}_${userName}_$title.pdf',
            response.bodyBytes.length,
            response.bodyBytes,
          ),
        );
      }

      final zipBytes = ZipEncoder().encode(archive);
      if (zipBytes == null) throw Exception('Nao foi possivel gerar o ZIP.');

      final month = selectedMonth.month.toString().padLeft(2, '0');
      final fileName = 'Documentos_Assinados_$month-${selectedMonth.year}';
      await FileSaver.instance.saveFile(
        name: fileName,
        bytes: Uint8List.fromList(zipBytes),
        ext: 'zip',
        mimeType: MimeType.zip,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${documents.length} documento(s) baixado(s).')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao baixar documentos: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloadingMonth = false);
    }
  }

  String _statusFilterLabel() {
    switch (_statusFilter) {
      case 'pending':
        return 'Aguardando assinatura';
      case 'signed':
        return 'Assinados';
      case 'error':
        return 'Com erro';
      default:
        return 'Todos';
    }
  }

  Widget _filterField({required String label, required Widget child}) {
    return Container(
      width: 310,
      height: 64,
      padding: const EdgeInsets.fromLTRB(16, 8, 14, 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFD8B5B1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF7A5B58))),
          const SizedBox(height: 3),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final peopleById = <String, String>{};
    for (final document in _documents) {
      final id = document['user_id']?.toString() ?? '';
      if (id.isNotEmpty) {
        peopleById[id] = document['user_name']?.toString().isNotEmpty == true
            ? document['user_name'].toString()
            : document['user_email']?.toString() ?? 'Colaborador';
      }
    }
    final people = peopleById.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final filteredDocuments = _documents.where((document) {
      final status = document['status']?.toString() ?? '';
      if (_statusFilter != 'all' && status != _statusFilter) return false;
      if (_isAdmin &&
          _personFilter != 'all' &&
          document['user_id']?.toString() != _personFilter) {
        return false;
      }
      if (_monthFilter != null) {
        final createdAt = DateTime.tryParse(
          document['created_at']?.toString() ?? '',
        )?.toLocal();
        if (createdAt == null ||
            createdAt.year != _monthFilter!.year ||
            createdAt.month != _monthFilter!.month) {
          return false;
        }
      }
      if (query.isEmpty) return true;
      final searchable = [
        document['title'],
        document['message'],
        if (_isAdmin) document['user_name'],
        if (_isAdmin) document['user_email'],
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
    final pendingDocuments = _documents
        .where((document) => document['status']?.toString() == 'pending')
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isAdmin ? 'Documentos da equipe' : 'Meus documentos'),
        actions: [
          if (_isAdmin)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TextButton.icon(
                onPressed: _downloadingMonth || _loading
                    ? null
                    : _downloadMonthDocuments,
                icon: _downloadingMonth
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: const Text('Baixar'),
                style: TextButton.styleFrom(
                  foregroundColor: wineColor,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          IconButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Pesquisar documentos'),
                content: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: _isAdmin
                        ? 'Título, mensagem, colaborador ou e-mail'
                        : 'Título ou mensagem',
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            ),
            icon: const Icon(Icons.search),
            tooltip: 'Pesquisar',
          ),
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Atualizar lista',
          ),
        ],
      ),
      floatingActionButton: _isAdmin
          ? FloatingActionButton.extended(
              onPressed: () async {
                final sent = await showDialog<bool>(
                  context: context,
                  builder: (_) => const _SendDocumentDialog(),
                );
                if (sent == true) await _load();
              },
              backgroundColor: wineColor,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.upload_file),
              label: const Text('Enviar PDF'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: wineColor))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      GestureDetector(
                        onTap: _pickMonth,
                        child: _filterField(
                          label: 'Mês',
                          child: Text(_monthFilter == null
                              ? 'Mês: todos'
                              : 'Mês: ${_monthFilter!.month.toString().padLeft(2, '0')}/${_monthFilter!.year}'),
                        ),
                      ),
                      if (_monthFilter != null)
                        ActionChip(
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: Color(0xFFD8B5B1)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          label: const Text('Limpar mês'),
                          onPressed: () => setState(() => _monthFilter = null),
                        ),
                      PopupMenuButton<String>(
                        onSelected: (value) =>
                            setState(() => _statusFilter = value),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'all', child: Text('Todos os status')),
                          PopupMenuItem(
                              value: 'pending',
                              child: Text('Aguardando assinatura')),
                          PopupMenuItem(
                              value: 'signed', child: Text('Assinados')),
                          PopupMenuItem(
                              value: 'error', child: Text('Com erro')),
                        ],
                        child: _filterField(
                          label: 'Status',
                          child: Row(
                            children: [
                              Expanded(child: Text(_statusFilterLabel())),
                              const Icon(Icons.keyboard_arrow_down, size: 20),
                            ],
                          ),
                        ),
                      ),
                      if (_isAdmin)
                        PopupMenuButton<String>(
                          onSelected: (value) =>
                              setState(() => _personFilter = value),
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'all',
                              child: Text('Todos os colaboradores'),
                            ),
                            ...people.map((entry) => PopupMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value,
                                      overflow: TextOverflow.ellipsis),
                                )),
                          ],
                          child: _filterField(
                            label: 'Colaborador',
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _personFilter == 'all'
                                        ? 'Todos os colaboradores'
                                        : peopleById[_personFilter] ??
                                            'Todos os colaboradores',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.keyboard_arrow_down, size: 20),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: filteredDocuments.isEmpty
                        ? ListView(
                            children: const [
                              SizedBox(height: 160),
                              Icon(Icons.description_outlined,
                                  size: 64, color: Colors.grey),
                              SizedBox(height: 12),
                              Center(child: Text('Nenhum documento enviado.')),
                            ],
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                            itemCount: filteredDocuments.length +
                                ((!_isAdmin && pendingDocuments.isNotEmpty)
                                    ? 1
                                    : 0),
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 12),
                            itemBuilder: (_, index) {
                              if (!_isAdmin &&
                                  pendingDocuments.isNotEmpty &&
                                  index == 0) {
                                final count = pendingDocuments.length;
                                return Card(
                                  color: const Color(0xFFFFF3E0),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.notification_important,
                                            color: Colors.deepOrange),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            count == 1
                                                ? 'Você tem um documento aguardando sua assinatura.'
                                                : 'Você tem $count documentos aguardando sua assinatura.',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }
                              final document = filteredDocuments[index -
                                  ((!_isAdmin && pendingDocuments.isNotEmpty)
                                      ? 1
                                      : 0)];
                              final status =
                                  document['status']?.toString() ?? 'pending';
                              final isSigned = status == 'signed';
                              return Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.picture_as_pdf,
                                              color: wineColor),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              document['title']?.toString() ??
                                                  'Documento',
                                              style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                          Chip(
                                            label: Text(_statusLabel(status)),
                                            labelStyle: TextStyle(
                                                color: _statusColor(status)),
                                          ),
                                        ],
                                      ),
                                      if (_isAdmin) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          document['user_name']?.toString() ??
                                              '',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                      if ((document['message'] ?? '')
                                          .toString()
                                          .isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Text(document['message'].toString()),
                                      ],
                                      if ((document['error_message'] ?? '')
                                          .toString()
                                          .isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                            document['error_message']
                                                .toString(),
                                            style: const TextStyle(
                                                color: Colors.red)),
                                      ],
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          if (!_isAdmin &&
                                              !isSigned &&
                                              (document['sign_url'] ?? '')
                                                  .toString()
                                                  .isNotEmpty)
                                            FilledButton.icon(
                                              onPressed: () => _openUrl(
                                                  document['sign_url']
                                                      ?.toString()),
                                              icon: const Icon(Icons.draw),
                                              label:
                                                  const Text('Assinar agora'),
                                            ),
                                          if (isSigned &&
                                              (document['signed_file_url'] ??
                                                      '')
                                                  .toString()
                                                  .isNotEmpty)
                                            _documentActionButton(
                                              onPressed: () => _openUrl(
                                                document['signed_file_url']
                                                    ?.toString(),
                                              ),
                                              icon: Icons.download,
                                              label: 'Abrir PDF assinado',
                                            ),
                                          _documentActionButton(
                                            onPressed: () =>
                                                _refreshDocument(document),
                                            icon: Icons.sync,
                                            label: 'Atualizar status',
                                          ),
                                          if (_isAdmin)
                                            _documentActionButton(
                                              onPressed: () =>
                                                  _deleteDocument(document),
                                              icon: Icons.delete_outline,
                                              label: 'Apagar documento',
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _SendDocumentDialog extends StatefulWidget {
  const _SendDocumentDialog();

  @override
  State<_SendDocumentDialog> createState() => _SendDocumentDialogState();
}

class _SendDocumentDialogState extends State<_SendDocumentDialog> {
  static const wineColor = Color(0xFF8B0000);
  final _apiService = ApiService();
  final _titleController = TextEditingController();
  final _messageController = TextEditingController();
  List<dynamic> _users = [];
  String? _selectedUserId;
  Map<String, dynamic>? _selectedUser;
  String? _fileName;
  Uint8List? _pdfBytes;
  bool _loadingUsers = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    try {
      final users = await _apiService.getUsers();
      users.removeWhere(
          (user) => user['role'] == 'admin' || user['role'] == 'manager');
      if (mounted) setState(() => _users = users);
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  Future<void> _pickPdf() async {
    try {
      final String fileName;
      final Uint8List fileBytes;
      final file = await pickPdfFromBrowser();
      if (file == null) return;
      fileName = file.name;
      fileBytes = file.bytes;

      if (!fileName.toLowerCase().endsWith('.pdf')) {
        throw Exception('Selecione um arquivo PDF.');
      }
      setState(() {
        _fileName = fileName;
        _pdfBytes = fileBytes;
        if (_titleController.text.trim().isEmpty) {
          _titleController.text = fileName.replaceFirst(
              RegExp(r'\.pdf$', caseSensitive: false), '');
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Nao foi possivel selecionar o arquivo: $e')),
        );
      }
    }
  }

  void _useSelectedPdf(SelectedPdfFile file) {
    if (!file.name.toLowerCase().endsWith('.pdf')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecione um arquivo PDF.')),
      );
      return;
    }
    setState(() {
      _fileName = file.name;
      _pdfBytes = file.bytes;
      if (_titleController.text.trim().isEmpty) {
        _titleController.text =
            file.name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
      }
    });
  }

  Future<void> _send() async {
    if (_selectedUserId == null ||
        _titleController.text.trim().isEmpty ||
        _pdfBytes == null ||
        _fileName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Selecione o colaborador, o titulo e o PDF.')),
      );
      return;
    }

    setState(() => _sending = true);
    try {
      await _apiService.createSignatureDocument(
        targetUserId: _selectedUserId!,
        targetUserName: _selectedUser?['name']?.toString() ?? 'Colaborador',
        targetUserEmail: _selectedUser?['email']?.toString() ?? '',
        title: _titleController.text.trim(),
        message: _messageController.text.trim(),
        fileName: _fileName!,
        pdfBytes: _pdfBytes!,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao enviar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enviar para assinatura'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_loadingUsers)
                const LinearProgressIndicator()
              else
                DropdownButtonFormField<String>(
                  initialValue: _selectedUserId,
                  decoration: const InputDecoration(labelText: 'Colaborador'),
                  items: _users
                      .map((user) => DropdownMenuItem<String>(
                            value: user['id'].toString(),
                            child: Text(user['name']?.toString() ??
                                user['email']?.toString() ??
                                'Colaborador'),
                          ))
                      .toList(),
                  onChanged: (value) => setState(() {
                    _selectedUserId = value;
                    final selected = _users.firstWhere(
                      (user) => user['id'].toString() == value,
                    );
                    _selectedUser = Map<String, dynamic>.from(selected as Map);
                  }),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _titleController,
                decoration:
                    const InputDecoration(labelText: 'Titulo do documento'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _messageController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Mensagem para o colaborador',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              if (!_sending)
                SizedBox(
                  width: 260,
                  height: 44,
                  child: WebPdfInput(
                    onSelected: _useSelectedPdf,
                    onError: (error) => ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('$error'))),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _sending ? null : _pickPdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: Text(_fileName ?? 'Selecionar PDF'),
                ),
              const SizedBox(height: 6),
              const Text('Limite da ZapSign: 10 MB',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          style: FilledButton.styleFrom(backgroundColor: wineColor),
          child: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Enviar'),
        ),
      ],
    );
  }
}
