import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/chat_timestamp.dart';
import 'chat_screen.dart';
import '../widgets/content_width.dart';

class UserChatListScreen extends StatefulWidget {
  const UserChatListScreen({super.key});

  @override
  State<UserChatListScreen> createState() => _UserChatListScreenState();
}

class _UserChatListScreenState extends State<UserChatListScreen> {
  static const Color wineColor = Color(0xFF8B0000);

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  String _periodFilter = 'day';
  bool _showTrash = false;

  Future<void> _startNewConversation() async {
    final docRef = _db.collection('adjustment_conversations').doc();

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ContentWidth(child: ChatScreen(conversationId: docRef.id, title: 'Nova conversa')),
      ),
    );
  }

  Stream<List<Map<String, dynamic>>> _watchConversations() {
    final user = _auth.currentUser;
    if (user == null) {
      return const Stream.empty();
    }

    return _db
        .collection('adjustment_conversations')
        .where('user_id', isEqualTo: user.uid)
        .snapshots()
        .map((snap) {
      final conversations = snap.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .where((conv) {
            final isDeleted = conv['deleted'] == true;
            return _showTrash ? isDeleted : !isDeleted;
          })
          .where(_matchesPeriodFilter)
          .toList();

      conversations.sort(
          (a, b) => chatConversationTime(b).compareTo(chatConversationTime(a)));
      return conversations;
    });
  }

  bool _matchesPeriodFilter(Map<String, dynamic> conv) {
    final lastTime = chatConversationTime(conv);
    if (lastTime.millisecondsSinceEpoch == 0) return true;

    final now = DateTime.now();
    final localLast = lastTime.toLocal();

    if (_periodFilter == 'day') {
      return localLast.year == now.year &&
          localLast.month == now.month &&
          localLast.day == now.day;
    }
    if (_periodFilter == 'week') {
      final startOfToday = DateTime(now.year, now.month, now.day);
      final startOfWeek =
          startOfToday.subtract(Duration(days: startOfToday.weekday - 1));
      return !localLast.isBefore(startOfWeek);
    }
    if (_periodFilter == 'month') {
      return localLast.year == now.year && localLast.month == now.month;
    }

    return true;
  }

  Future<void> _deleteConversation(Map<String, dynamic> conv) async {
    final confirmed = await _confirmWithApagar(
      title: 'Apagar conversa?',
      message:
          'Essa conversa vai sair da lista principal e ir para a lixeira. Digite APAGAR para confirmar.',
    );
    if (!confirmed) return;

    final user = _auth.currentUser;
    final userName = (conv['user_name'] ?? user?.email ?? 'usuario').toString();
    final conversationId = conv['id']?.toString();
    if (conversationId == null) return;

    try {
      await _db.collection('adjustment_conversations').doc(conversationId).set({
        'deleted': true,
        'deleted_at': DateTime.now().toIso8601String(),
        'deleted_by_type': 'user',
        'deleted_by_name': userName,
      }, SetOptions(merge: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro ao apagar conversa: $e')),
      );
    }
  }

  void _showConversationOptions(Map<String, dynamic> conv) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Apagar conversa'),
              onTap: () {
                Navigator.pop(context);
                _deleteConversation(conv);
              },
            ),
          ],
        ),
      ),
    );
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
        title: Text(_showTrash ? 'Lixeira' : 'Suas conversas',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: wineColor,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: _showTrash ? 'Conversas' : 'Lixeira',
            icon: Icon(_showTrash ? Icons.chat_bubble_outline : Icons.delete),
            onPressed: () => setState(() => _showTrash = !_showTrash),
          ),
        ],
      ),
      floatingActionButton: _showTrash
          ? null
          : FloatingActionButton(
              backgroundColor: wineColor,
              foregroundColor: Colors.white,
              onPressed: _startNewConversation,
              child: const Icon(Icons.add_comment),
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'day', label: Text('Diario')),
                ButtonSegment(value: 'week', label: Text('Semanal')),
                ButtonSegment(value: 'month', label: Text('Mensal')),
                ButtonSegment(value: 'all', label: Text('Todas')),
              ],
              selected: {_periodFilter},
              onSelectionChanged: (value) =>
                  setState(() => _periodFilter = value.first),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _watchConversations(),
              initialData: const [],
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                      child: Text(
                          'Erro ao carregar conversas: ${snapshot.error}'));
                }

                final conversations = snapshot.data ?? [];
                if (conversations.isEmpty) {
                  return Center(
                    child: Text(
                      _showTrash
                          ? 'Nenhuma conversa na lixeira.'
                          : 'Nenhuma conversa nesse filtro.',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: conversations.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final conv = conversations[index];
                    final lastTime = chatConversationTime(conv);
                    final title = (conv['title'] ?? 'Conversa').toString();
                    final subtitle = (conv['last_message'] ?? '').toString();

                    return Card(
                      elevation: 1,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              _showTrash ? Colors.grey.shade700 : wineColor,
                          child: Icon(
                            _showTrash
                                ? Icons.delete_outline
                                : Icons.chat_bubble_outline,
                            color: Colors.white,
                          ),
                        ),
                        title: Text(title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          _showTrash ? _deletedNotice(conv) : subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (lastTime.millisecondsSinceEpoch != 0)
                              Text(DateFormat('dd/MM HH:mm').format(lastTime),
                                  style: const TextStyle(fontSize: 11)),
                            if (_showTrash)
                              IconButton(
                                tooltip: 'Recuperar conversa',
                                icon: const Icon(Icons.restore),
                                color: wineColor,
                                onPressed: () => _restoreConversation(conv),
                              ),
                          ],
                        ),
                        onLongPress: _showTrash
                            ? null
                            : () => _showConversationOptions(conv),
                        onTap: _showTrash
                            ? null
                            : () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ContentWidth(child: ChatScreen(
                                        conversationId: conv['id'],
                                        title: title)),
                                  ),
                                );
                              },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
