import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/api_service.dart';
import 'admin_user_conversations_screen.dart';
import '../widgets/content_width.dart';

class AdminChatListScreen extends StatefulWidget {
  const AdminChatListScreen({super.key});

  @override
  State<AdminChatListScreen> createState() => _AdminChatListScreenState();
}

class _AdminChatListScreenState extends State<AdminChatListScreen> {
  static const Color wineColor = Color(0xFF8B0000);

  final _apiService = ApiService();
  final _db = FirebaseFirestore.instance;
  bool _isLoading = true;
  bool _showTrash = false;
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _deletedConversations = [];

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() => _isLoading = true);
    try {
      final all = await _apiService.getAllAdjustmentRequests();
      final conversationsSnap =
          await _db.collection('adjustment_conversations').get();
      final conversationMeta = {
        for (final doc in conversationsSnap.docs)
          doc.id: {'id': doc.id, ...doc.data()}
      };
      final Map<String, Map<String, dynamic>> grouped = {};

      for (final req in all) {
        final userId = req['user_id']?.toString();
        if (userId == null) continue;

        final conversationId = req['conversation_id']?.toString();
        if (conversationId != null &&
            conversationMeta[conversationId]?['deleted'] == true) {
          continue;
        }

        final timestamp =
            DateTime.tryParse(req['timestamp']?.toString() ?? '') ??
                DateTime.now();
        final isUnread = req['status'] == 'unread';

        grouped.putIfAbsent(userId, () {
          return {
            'user_id': userId,
            'user_name': req['user_name']?.toString() ?? 'Usuario',
            'last_message': req['message']?.toString() ?? '[Audio]',
            'last_time': timestamp,
            'unread_count': 0,
            'requests': <Map<String, dynamic>>[],
          };
        });

        grouped[userId]!['requests'].add(req);
        if (isUnread) grouped[userId]!['unread_count']++;
        if (timestamp.isAfter(grouped[userId]!['last_time'] as DateTime)) {
          grouped[userId]!['last_time'] = timestamp;
          grouped[userId]!['last_message'] =
              req['message']?.toString() ?? '[Audio]';
        }
      }

      final deleted = conversationMeta.values
          .where((conv) => conv['deleted'] == true)
          .toList()
        ..sort((a, b) => (b['deleted_at'] as String? ?? '')
            .compareTo(a['deleted_at'] as String? ?? ''));

      setState(() {
        _users = grouped.values.toList()
          ..sort((a, b) => (b['last_time'] as DateTime)
              .compareTo(a['last_time'] as DateTime));
        _deletedConversations = deleted;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Erro load admin users chats: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _restoreConversation(Map<String, dynamic> conv) async {
    final conversationId = conv['id']?.toString();
    if (conversationId == null) return;

    await _db.collection('adjustment_conversations').doc(conversationId).set({
      'deleted': false,
      'deleted_at': null,
      'deleted_by_type': null,
      'deleted_by_name': null,
    }, SetOptions(merge: true));
    await _loadUsers();
  }

  String _deletedNotice(Map<String, dynamic> conv) {
    final type = conv['deleted_by_type']?.toString();
    final name = conv['deleted_by_name']?.toString();

    if (type == 'admin') return 'Conversa apagada por admin';
    if (name != null && name.isNotEmpty) return 'Conversa apagada por $name';
    return 'Conversa apagada pelo usuario';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showTrash ? 'Lixeira de conversas' : 'Conversas de Ajuste',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: wineColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: _showTrash ? 'Conversas' : 'Lixeira',
            icon: Icon(_showTrash ? Icons.people_alt_outlined : Icons.delete),
            onPressed: () => setState(() => _showTrash = !_showTrash),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: wineColor))
          : _showTrash
              ? _buildTrashList()
              : _buildUserList(),
    );
  }

  Widget _buildUserList() {
    if (_users.isEmpty) {
      return const Center(
        child: Text('Nenhuma conversa encontrada.',
            style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadUsers,
      color: wineColor,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _users.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final user = _users[index];
          final userName = user['user_name']?.toString() ?? 'Usuario';
          final unreadCount = user['unread_count'] as int;
          final hasUnread = unreadCount > 0;

          return Card(
            elevation: hasUnread ? 4 : 1,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: ListTile(
              leading: Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    backgroundColor: wineColor,
                    child: Text(userName[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white)),
                  ),
                  if (hasUnread)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              title: Text(userName,
                  style: TextStyle(
                      fontWeight:
                          hasUnread ? FontWeight.bold : FontWeight.normal)),
              subtitle: Text(
                hasUnread
                    ? '$unreadCount conversa(s) com novidade'
                    : user['last_message']?.toString() ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                DateFormat('dd/MM HH:mm').format(user['last_time'] as DateTime),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContentWidth(child: AdminUserConversationsScreen(
                      userId: user['user_id'],
                      userName: userName,
                      requests:
                          List<Map<String, dynamic>>.from(user['requests']),
                    )),
                  ),
                );
                _loadUsers();
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildTrashList() {
    if (_deletedConversations.isEmpty) {
      return const Center(
        child: Text('Nenhuma conversa na lixeira.',
            style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadUsers,
      color: wineColor,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _deletedConversations.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final conv = _deletedConversations[index];
          final userName = conv['user_name']?.toString() ?? 'Usuario';
          final deletedAt =
              DateTime.tryParse((conv['deleted_at'] ?? '').toString());

          return Card(
            elevation: 1,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.grey.shade700,
                child: const Icon(Icons.delete_outline, color: Colors.white),
              ),
              title:
                  Text(userName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_deletedNotice(conv),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (deletedAt != null)
                    Text(DateFormat('dd/MM HH:mm').format(deletedAt),
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                  IconButton(
                    tooltip: 'Recuperar conversa',
                    icon: const Icon(Icons.restore),
                    color: wineColor,
                    onPressed: () => _restoreConversation(conv),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
