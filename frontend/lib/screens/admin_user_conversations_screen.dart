import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/chat_timestamp.dart';
import 'admin_chat_detail_screen.dart';
import '../widgets/content_width.dart';

class AdminUserConversationsScreen extends StatefulWidget {
  final String userId;
  final String userName;
  final List<Map<String, dynamic>> requests;

  const AdminUserConversationsScreen({
    super.key,
    required this.userId,
    required this.userName,
    required this.requests,
  });

  @override
  State<AdminUserConversationsScreen> createState() =>
      _AdminUserConversationsScreenState();
}

class _AdminUserConversationsScreenState
    extends State<AdminUserConversationsScreen> {
  static const Color wineColor = Color(0xFF8B0000);

  final _db = FirebaseFirestore.instance;
  late List<Map<String, dynamic>> _requests;
  Map<String, Map<String, dynamic>> _conversationMeta = {};

  @override
  void initState() {
    super.initState();
    _requests = widget.requests;
    Future.microtask(_reload);
  }

  Future<void> _reload() async {
    final requestSnap = await _db
        .collection('adjustment_requests')
        .where('user_id', isEqualTo: widget.userId)
        .get();
    final conversationSnap = await _db
        .collection('adjustment_conversations')
        .where('user_id', isEqualTo: widget.userId)
        .get();

    if (!mounted) return;
    setState(() {
      _requests =
          requestSnap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
      _conversationMeta = {
        for (final doc in conversationSnap.docs)
          doc.id: {'id': doc.id, ...doc.data()}
      };
    });
  }

  List<Map<String, dynamic>> _groupConversations() {
    final Map<String, Map<String, dynamic>> grouped = {};

    for (final req in _requests) {
      final conversationId = req['conversation_id']?.toString();
      final groupId = conversationId ?? 'legacy-${req['id']}';
      final meta =
          conversationId == null ? null : _conversationMeta[conversationId];
      if (meta?['deleted'] == true) continue;

      final timestamp = chatMessageTime(req);
      final isUnread = req['status'] == 'unread';

      grouped.putIfAbsent(groupId, () {
        return {
          'conversation_id': conversationId,
          'user_id': widget.userId,
          'user_name': widget.userName,
          'last_message': req['message']?.toString() ?? '[Audio]',
          'last_time': timestamp,
          'unread_count': 0,
          'requests': <Map<String, dynamic>>[],
        };
      });

      grouped[groupId]!['requests'].add(req);
      if (isUnread) grouped[groupId]!['unread_count']++;
      if (timestamp.isAfter(grouped[groupId]!['last_time'] as DateTime)) {
        grouped[groupId]!['last_time'] = timestamp;
        grouped[groupId]!['last_message'] =
            req['message']?.toString() ?? '[Audio]';
      }
    }

    return grouped.values.toList()
      ..sort((a, b) =>
          (b['last_time'] as DateTime).compareTo(a['last_time'] as DateTime));
  }

  Future<void> _setConversationReadState(
      Map<String, dynamic> conversation, bool unread) async {
    final batch = _db.batch();
    final requests = List<Map<String, dynamic>>.from(conversation['requests']);

    for (final req in requests) {
      final id = req['id']?.toString();
      if (id == null) continue;
      batch.update(_db.collection('adjustment_requests').doc(id), {
        'status': unread ? 'unread' : 'read',
      });
    }

    await batch.commit();
    await _reload();
  }

  Future<void> _deleteConversation(Map<String, dynamic> conversation) async {
    final conversationId = conversation['conversation_id']?.toString();
    if (conversationId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Essa conversa antiga nao pode ir para a lixeira.')));
      }
      return;
    }

    final confirmed = await _confirmWithApagar(
      title: 'Apagar conversa?',
      message:
          'Essa conversa vai sair da lista do admin e do usuario. Digite APAGAR para confirmar.',
    );
    if (!confirmed) return;

    final batch = _db.batch();
    batch.set(
      _db.collection('adjustment_conversations').doc(conversationId),
      {
        'deleted': true,
        'deleted_at': DateTime.now().toIso8601String(),
        'deleted_by_type': 'admin',
        'deleted_by_name': 'admin',
      },
      SetOptions(merge: true),
    );

    for (final req
        in List<Map<String, dynamic>>.from(conversation['requests'])) {
      final id = req['id']?.toString();
      if (id == null) continue;
      batch.update(_db.collection('adjustment_requests').doc(id), {
        'status': 'read',
      });
    }

    await batch.commit();
    await _reload();
  }

  Future<bool> _confirmWithApagar({
    required String title,
    required String message,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Digite APAGAR',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCELAR'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, controller.text.trim() == 'APAGAR'),
            child: const Text('APAGAR', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    controller.dispose();
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    final conversations = _groupConversations();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.userName,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: wineColor,
        foregroundColor: Colors.white,
      ),
      body: conversations.isEmpty
          ? const Center(
              child: Text('Nenhuma conversa encontrada.',
                  style: TextStyle(color: Colors.grey)))
          : RefreshIndicator(
              color: wineColor,
              onRefresh: _reload,
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: conversations.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final conversation = conversations[index];
                  final unreadCount = conversation['unread_count'] as int;
                  final hasUnread = unreadCount > 0;

                  return Card(
                    elevation: hasUnread ? 4 : 1,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    child: ListTile(
                      leading: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          CircleAvatar(
                            backgroundColor:
                                hasUnread ? wineColor : Colors.grey.shade600,
                            child: const Icon(Icons.chat_bubble_outline,
                                color: Colors.white),
                          ),
                          if (hasUnread)
                            Positioned(
                              right: -2,
                              top: -2,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.white, width: 2),
                                ),
                                child: Text(
                                  unreadCount.toString(),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                        ],
                      ),
                      title: Text(
                        conversation['last_message']?.toString() ?? 'Conversa',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: hasUnread
                                ? FontWeight.bold
                                : FontWeight.normal),
                      ),
                      subtitle: Text(
                        hasUnread ? 'Nao lida' : 'Lida',
                        style: TextStyle(
                            color: hasUnread ? wineColor : Colors.grey),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            DateFormat('dd/MM HH:mm')
                                .format(conversation['last_time'] as DateTime),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: hasUnread
                                ? 'Marcar como lida'
                                : 'Marcar como nao lida',
                            icon: Icon(hasUnread
                                ? Icons.mark_email_read_outlined
                                : Icons.mark_email_unread_outlined),
                            color: wineColor,
                            onPressed: () => _setConversationReadState(
                                conversation, !hasUnread),
                          ),
                          IconButton(
                            tooltip: 'Apagar conversa',
                            icon: const Icon(Icons.delete_outline),
                            color: Colors.red,
                            onPressed: () => _deleteConversation(conversation),
                          ),
                        ],
                      ),
                      onTap: () async {
                        if (hasUnread) {
                          await _setConversationReadState(conversation, false);
                        }
                        if (!context.mounted) return;
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ContentWidth(child: AdminChatDetailScreen(
                              conversationId: conversation['conversation_id'],
                              userId: widget.userId,
                              userName: widget.userName,
                              requests: List<Map<String, dynamic>>.from(
                                  conversation['requests']),
                            )),
                          ),
                        );
                        _reload();
                      },
                    ),
                  );
                },
              ),
            ),
    );
  }
}
