import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../screens/chat_screen.dart';
import '../services/api_service.dart';
import 'content_width.dart';
import '../utils/screen_watch.dart';

class UserNotificationBell extends StatefulWidget {
  const UserNotificationBell({super.key});

  @override
  State<UserNotificationBell> createState() => _UserNotificationBellState();
}

class _UserNotificationBellState extends State<UserNotificationBell> {
  static const _wineColor = Color(0xFF8B0000);
  final _apiService = ApiService();
  List<Map<String, dynamic>> _documentNotifications = [];
  List<Map<String, dynamic>> _userNotifications = [];
  List<Map<String, dynamic>> _scheduleRequests = [];
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    // 2 min em vez de 30s: o push ja avisa na hora; este polling e so rede de
    // seguranca e roda em toda aba aberta o dia inteiro, custando leitura.
    _pollTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (mounted && isScreenWatched(context)) _loadNotifications();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadNotifications() async {
    final results = await Future.wait([
      _apiService
          .getSignatureNotifications()
          .catchError((_) => <Map<String, dynamic>>[]),
      _apiService
          .getUserNotifications()
          .catchError((_) => <Map<String, dynamic>>[]),
    ]);
    var scheduleRequests = <Map<String, dynamic>>[];
    try {
      final user = await _apiService.getCurrentUser();
      if (user['role'] == 'admin' || user['role'] == 'manager') {
        scheduleRequests =
            await _apiService.getScheduleApprovalRequests(status: 'pending');
      }
    } catch (_) {
      // A fila continua disponivel na aba de liberacoes.
    }
    if (mounted) {
      setState(() {
        _documentNotifications = results[0];
        _userNotifications = results[1];
        _scheduleRequests = scheduleRequests;
      });
    }
  }

  Stream<List<Map<String, dynamic>>> _unreadManagerMessages() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Stream.empty();

    // O filtro de remetente vai para o Firestore: so as mensagens do gestor
    // interessam aqui, e antes o listener baixava a conversa inteira do usuario
    // toda vez que o sininho era montado (ou seja, em cada troca de tela).
    // 'notification_read' fica no filtro em memoria de proposito: mensagem
    // antiga sem esse campo nao casa com igualdade e sumiria da contagem.
    return FirebaseFirestore.instance
        .collection('adjustment_requests')
        .where('user_id', isEqualTo: user.uid)
        .where('sender_role', isEqualTo: 'admin')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => {'id': doc.id, ...doc.data()})
            .where((message) => message['notification_read'] != true)
            .toList());
  }

  Future<void> _openNotifications(
      List<Map<String, dynamic>> managerMessages) async {
    final unreadDocuments = _documentNotifications
        .where((notification) => notification['is_read'] != 1)
        .toList();
    final unreadUserNotifications = _userNotifications
        .where((notification) => notification['is_read'] != true)
        .toList();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: ListView(
            shrinkWrap: true,
            children: [
              const Text('Notificações',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              if (managerMessages.isEmpty &&
                  unreadDocuments.isEmpty &&
                  unreadUserNotifications.isEmpty &&
                  _scheduleRequests.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(child: Text('Nenhuma notificação nova.')),
                ),
              ...managerMessages.map((message) => ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0x1A8B0000),
                      child: Icon(Icons.chat_outlined, color: _wineColor),
                    ),
                    title: const Text('Resposta da gestão'),
                    subtitle: Text(message['message']?.toString() ?? 'Áudio'),
                    onTap: () async {
                      await FirebaseFirestore.instance
                          .collection('adjustment_requests')
                          .doc(message['id'])
                          .update({'notification_read': true});
                      if (!mounted || !context.mounted) return;
                      Navigator.pop(context);
                      Navigator.of(this.context).push(MaterialPageRoute(
                        builder: (_) => ContentWidth(child: ChatScreen(
                          conversationId:
                              message['conversation_id']?.toString() ?? '',
                          title: 'Ajuste de ponto',
                        )),
                      ));
                    },
                  )),
              ...unreadDocuments.map((notification) => ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0x1A8B0000),
                      child:
                          Icon(Icons.description_outlined, color: _wineColor),
                    ),
                    title:
                        Text(notification['title']?.toString() ?? 'Documento'),
                    subtitle: Text(notification['body']?.toString() ?? ''),
                  )),
              ...unreadUserNotifications.map((notification) => ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0x1A8B0000),
                      child: Icon(
                        notification['type'] == 'schedule_approval'
                            ? Icons.approval_outlined
                            : Icons.schedule_outlined,
                        color: _wineColor,
                      ),
                    ),
                    title: Text(notification['title']?.toString() ??
                        'Atualizacao de horario'),
                    subtitle: Text(notification['body']?.toString() ?? ''),
                  )),
              ..._scheduleRequests.map((request) => ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: Color(0x1A8B0000),
                      child: Icon(Icons.more_time, color: _wineColor),
                    ),
                    title: const Text('Liberação de horário pendente'),
                    subtitle: Text(
                      '${request['user_name'] ?? 'Estagiário'} • ${request['request_type'] == 'start_exception' ? 'entrada fora do horário' : 'continuar expediente'}',
                    ),
                  )),
            ],
          ),
        ),
      ),
    );

    if (unreadDocuments.isNotEmpty) {
      await _apiService.markSignatureNotificationsRead();
    }
    if (unreadUserNotifications.isNotEmpty) {
      await _apiService.markUserNotificationsRead();
    }
    await _loadNotifications();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _unreadManagerMessages(),
      initialData: const [],
      builder: (context, snapshot) {
        final messages = snapshot.data ?? [];
        final unreadDocuments = _documentNotifications
            .where((notification) => notification['is_read'] != 1)
            .length;
        final unreadUserNotifications = _userNotifications
            .where((notification) => notification['is_read'] != true)
            .length;
        final total = messages.length +
            unreadDocuments +
            unreadUserNotifications +
            _scheduleRequests.length;

        return IconButton(
          tooltip: 'Notificações',
          onPressed: () => _openNotifications(messages),
          icon: Badge(
            isLabelVisible: total > 0,
            label: Text(total.toString()),
            child: const Icon(
              Icons.notifications_active_outlined,
              color: _wineColor,
              size: 28,
            ),
          ),
        );
      },
    );
  }
}
