import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import '../utils/work_schedule_rules.dart' show isInternProfile;
import '../utils/chat_timestamp.dart';
import '../utils/cpf.dart';
import '../utils/daily_entries.dart';
import '../utils/shift_records.dart';
import '../utils/timesheet.dart';

class AdjustmentRequestResult {
  final String id;
  final String? audioUrl;
  final bool audioUploadPending;

  const AdjustmentRequestResult({
    required this.id,
    this.audioUrl,
    this.audioUploadPending = false,
  });
}

/// Batida recusada pelas regras de horario (backend ou fallback), nao por
/// falta de rede: reenviar igual nao muda nada. O texto e o mesmo de uma
/// Exception comum, para a mensagem na tela nao mudar.
class PunchRejectedException implements Exception {
  const PunchRejectedException(this.message, {this.awaitingApproval = false});

  final String message;

  /// Recusada so por falta da liberacao do gestor: com a liberacao, a mesma
  /// batida passa.
  final bool awaitingApproval;

  @override
  String toString() => 'Exception: $message';
}

/// Backend fora do ar (404/5xx) numa batida: a batida vai para a fila
/// offline e a sincronizacao reenvia pelo backend. Antes o app gravava pelo
/// plano B direto no Firestore; com as regras fechadas (so o backend e o
/// lote do gestor gravam ponto) esse caminho nao existe mais.
class ServerUnavailableException implements Exception {
  const ServerUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'Exception: $message';
}

/// Resposta de erro do backend nas diarias (/daily-entries).
class _DailyEntryHttpException implements Exception {
  const _DailyEntryHttpException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  /// Servidor fora do ar ou sem cota: a mesma diaria passa mais tarde.
  bool get temporary => statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'Exception: $message';
}

class ApiService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  static const String _offlineRecordsKey = 'offline_time_records';
  static const String _cachedUserKey = 'cached_current_user';
  // Ultimo CPF (ou e-mail) digitado no login. Fica mesmo depois de sair da
  // conta, para a tela de login ja abrir preenchida (com ou sem internet).
  static const String _lastLoginKey = 'last_login_id';
  // O do login por e-mail, de antes do login por CPF.
  static const String _lastLoginEmailKey = 'last_login_email';
  // Copia local dos pontos do proprio usuario (ultimos dias). No web o cache
  // do Firestore fica desligado (o IndexedDB trava no Safari do iPhone), entao
  // e esta copia que mostra o status do dia sem internet e na abertura.
  static const String _recordsCachePrefix = 'cached_time_records_';
  static const int _recordsCacheDays = 15;
  static String get backendUrl => AppConfig.backendUrl;

  Future<Map<String, String>> _authorizedHeaders() async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuario nao autenticado.');
    final token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw Exception('Nao foi possivel renovar sua sessao. Entre novamente.');
    }
    return {'Authorization': 'Bearer $token'};
  }

  /// O backend falhou (404/5xx) e a operacao segue pelo plano B direto no
  /// Firestore. Fica registrado: foi um plano B silencioso que escondeu por
  /// meses o erro 500 em toda batida de estagiario.
  void _logPlanB(http.Response response) => debugPrint(
      'Plano B pelo Firestore: ${response.request?.method} '
      '${response.request?.url.path} respondeu ${response.statusCode}');

  String _apiError(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded['detail']?.toString() ?? response.body;
    } catch (_) {
      return response.body;
    }
  }

  Future<List<Map<String, dynamic>>> getSignatureDocuments(
      {required bool admin}) async {
    final response = await http
        .get(
          Uri.parse(admin
              ? '$backendUrl/admin/signature-documents'
              : '$backendUrl/signature-documents'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as List;
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createSignatureDocument({
    required String targetUserId,
    required String targetUserName,
    required String targetUserEmail,
    required String title,
    required String message,
    required String fileName,
    required Uint8List pdfBytes,
  }) async {
    final documentId =
        '${DateTime.now().microsecondsSinceEpoch}_${targetUserId.substring(0, 6)}';
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$backendUrl/admin/signature-documents'),
    );
    request.headers.addAll(await _authorizedHeaders());
    request.fields.addAll({
      'target_user_id': targetUserId,
      'target_user_name': targetUserName,
      'target_user_email': targetUserEmail,
      'local_document_id': documentId,
      'title': title,
      'message': message,
    });
    request.files.add(http.MultipartFile.fromBytes(
      'pdf',
      pdfBytes,
      filename: fileName,
    ));

    final streamed = await request.send().timeout(const Duration(seconds: 90));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  Future<Map<String, dynamic>> _updateUserAdminInFirestore(
    String userId, {
    required String name,
    required String email,
    required String role,
    required String jobTitle,
    required double dailyHours,
    required String cpf,
    required bool disabled,
    String? newPassword,
    required bool workScheduleOverrideEnabled,
    Map<String, dynamic>? workScheduleOverride,
    required bool dailyMode,
  }) async {
    final admin = await getCurrentUser();
    if (admin['role'] != 'admin') {
      throw Exception('Apenas administradores podem editar usuarios.');
    }

    final userRef = _db.collection('users').doc(userId);
    final snapshot = await userRef.get();
    if (!snapshot.exists || snapshot.data() == null) {
      throw Exception('Usuario nao encontrado.');
    }
    final current = snapshot.data()!;
    final currentEmail =
        (current['email'] ?? '').toString().trim().toLowerCase();
    final requestedEmail = email.trim().toLowerCase();
    if (requestedEmail != currentEmail) {
      throw Exception(
          'Para alterar o e-mail de login, configure a credencial Firebase Admin no servidor.');
    }
    if ((newPassword ?? '').trim().isNotEmpty) {
      throw Exception(
          'Para redefinir a senha, configure a credencial Firebase Admin no servidor.');
    }
    if (disabled != (current['disabled'] == true)) {
      throw Exception(
          'Para ativar ou desativar a conta, configure a credencial Firebase Admin no servidor.');
    }

    final updateData = <String, dynamic>{
      'name': name.trim(),
      'email': currentEmail,
      'role': role,
      'job_title': jobTitle.trim(),
      'daily_hours': dailyHours,
      'cpf': cpf.trim(),
      // O login por CPF procura por este campo: sem ele, a troca de CPF por
      // aqui deixava o backend buscando pelo CPF antigo.
      'cpf_digits': cpfDigits(cpf),
      'disabled': disabled,
      'work_schedule_override_enabled': workScheduleOverrideEnabled,
      'work_schedule_override':
          workScheduleOverrideEnabled ? workScheduleOverride : null,
      'daily_mode': dailyMode && role != 'intern' && role != 'estagiario',
      'updated_at': FieldValue.serverTimestamp(),
      'last_admin_update_by_id': admin['id'],
      'last_admin_update_by_name': admin['name'] ?? '',
      'last_admin_update_by_email': admin['email'] ?? '',
      'compatibility_mode': true,
    };
    final auditRef = _db.collection('system_audits').doc();
    final batch = _db.batch();
    batch.update(userRef, updateData);
    batch.set(auditRef, {
      'action': 'update_user_admin_compatibility',
      'target_user_id': userId,
      'admin_id': admin['id'],
      'admin_name': admin['name'] ?? '',
      'admin_email': admin['email'] ?? '',
      'updated_fields': [
        'name',
        'role',
        'job_title',
        'daily_hours',
        'cpf',
        'work_schedule_override_enabled',
        'work_schedule_override',
        'daily_mode',
      ],
      'created_at': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    invalidateUsersCache();
    return {'status': 'success', 'id': userId, 'compatibility_mode': true};
  }

  Future<Map<String, dynamic>> refreshSignatureDocument(
      String documentId) async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/signature-documents/$documentId/refresh'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  Future<void> deleteSignatureDocument(String documentId) async {
    final response = await http
        .delete(
          Uri.parse('$backendUrl/admin/signature-documents/$documentId'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
  }

  Future<List<Map<String, dynamic>>> getSignatureNotifications() async {
    final response = await http
        .get(
          Uri.parse('$backendUrl/signature-notifications'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as List;
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<void> markSignatureNotificationsRead() async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/signature-notifications/read'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
  }

  Future<void> _cacheCurrentUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedUser = <String, dynamic>{
      for (final key in const [
        'id',
        'uid',
        'email',
        'name',
        'cpf',
        'role',
        'job_title',
        'daily_hours',
        'disabled',
        'work_schedule_override_enabled',
        'work_schedule_override',
        // Modo diaria: decide a tela de ponto tambem na abertura sem internet.
        'daily_mode',
        // Primeiro acesso (ou senha redefinida pelo admin): a tela de criar
        // senha aparece antes de tudo.
        'must_change_password',
      ])
        if (user[key] != null) key: user[key],
    };
    await prefs.setString(_cachedUserKey, jsonEncode(cachedUser));
  }

  Future<Map<String, dynamic>?> getCachedCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final rawUser = prefs.getString(_cachedUserKey);
    if (rawUser == null || rawUser.isEmpty) return null;

    try {
      return Map<String, dynamic>.from(jsonDecode(rawUser) as Map);
    } catch (e) {
      debugPrint('Erro ao ler perfil offline: $e');
      await prefs.remove(_cachedUserKey);
      return null;
    }
  }

  Future<bool> hasCachedSession() async {
    return await getCachedCurrentUser() != null;
  }

  Future<bool> _hasNetworkConnection() async {
    final results = await Connectivity().checkConnectivity();
    return !results.contains(ConnectivityResult.none);
  }

  // --- MÉTODOS DE AJUSTE (CHAT INTERNO) ---

  Future<AdjustmentRequestResult> createAdjustmentRequest(
      {String? text, Uint8List? audioBytes}) async {
    final user = await getCurrentUser();
    final hasAudio = audioBytes != null;

    try {
      final docRef = await _db.collection('adjustment_requests').add({
        'user_id': user['id'],
        'user_name': user['name'],
        'message': text ?? (hasAudio ? 'Mensagem de áudio' : null),
        'audio_url': null,
        'audio_upload_status': hasAudio ? 'uploading' : null,
        'timestamp': DateTime.now().toIso8601String(),
        'created_at': FieldValue.serverTimestamp(),
        'status': 'unread',
      });

      debugPrint('ApiService: Documento Firestore criado: ${docRef.id}');

      if (hasAudio) {
        unawaited(_uploadAndAttachAdjustmentAudio(
          requestId: docRef.id,
          audioBytes: audioBytes,
        ));
      }

      return AdjustmentRequestResult(
          id: docRef.id, audioUploadPending: hasAudio);
    } catch (e) {
      debugPrint('ERRO CRÍTICO em createAdjustmentRequest: $e');
      rethrow;
    }
  }

  Future<void> _uploadAndAttachAdjustmentAudio({
    required String requestId,
    Uint8List? audioBytes,
  }) async {
    try {
      if (audioBytes == null) throw Exception('Áudio não encontrado para upload.');
      debugPrint(
          'ApiService: Iniciando upload áudio (${audioBytes.length} bytes)');
      final audioUrl = await uploadAdjustmentAudioWeb(audioBytes);

      await _db.collection('adjustment_requests').doc(requestId).update({
        'audio_url': audioUrl,
        'audio_upload_status': 'sent',
      });
      debugPrint('ApiService: Upload concluído e anexado. URL: $audioUrl');
    } catch (e) {
      debugPrint('Erro ao anexar áudio no ajuste $requestId: $e');
      if (audioBytes != null &&
          await _embedAudioInRequest(requestId, audioBytes, 'audio/webm')) {
        return;
      }

      try {
        await _db.collection('adjustment_requests').doc(requestId).update({
          'audio_upload_status': 'error',
          'audio_upload_error': e.toString(),
        }).timeout(const Duration(seconds: 10));
      } catch (updateError) {
        debugPrint(
            'Erro ao atualizar status do áudio no ajuste $requestId: $updateError');
      }
    }
  }

  Future<bool> _embedAudioInRequest(
      String requestId, Uint8List bytes, String mimeType) async {
    const maxEmbeddedBytes = 700 * 1024;
    if (bytes.length > maxEmbeddedBytes) {
      debugPrint(
          'Áudio muito grande para embutir no Firestore: ${bytes.length} bytes');
      return false;
    }

    try {
      await _db.collection('adjustment_requests').doc(requestId).update({
        'audio_data_url': 'data:$mimeType;base64,${base64Encode(bytes)}',
        'audio_mime_type': mimeType,
        'audio_upload_status': 'embedded',
      }).timeout(const Duration(seconds: 15));
      debugPrint(
          'Áudio embutido no Firestore como fallback (${bytes.length} bytes)');
      return true;
    } catch (e) {
      debugPrint('Erro ao embutir áudio no Firestore: $e');
      return false;
    }
  }

  Future<String> uploadAdjustmentAudioWeb(Uint8List bytes) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Usuário não logado');

    final ref = _storage.ref().child(
        'adjustments/${user.uid}/${DateTime.now().millisecondsSinceEpoch}.webm');

    // Configura o metadata para garantir que o navegador entenda que é um áudio
    final metadata = SettableMetadata(
      contentType: 'audio/webm',
      customMetadata: {'platform': 'web'},
    );

    final uploadTask = ref.putData(bytes, metadata);

    // Acompanha o progresso (opcional, mas bom para debug)
    final progressSubscription = uploadTask.snapshotEvents.listen((event) {
      debugPrint(
          'Upload progress: ${event.bytesTransferred}/${event.totalBytes}');
    });

    try {
      final snapshot = await uploadTask.timeout(
        const Duration(seconds: 120),
        onTimeout: () async {
          await uploadTask.cancel();
          throw TimeoutException(
              'Upload do áudio demorou mais de 120 segundos.');
        },
      );
      return await snapshot.ref.getDownloadURL();
    } finally {
      await progressSubscription.cancel();
    }
  }

  Stream<int> getUnreadAdjustmentsCount() {
    return _db
        .collection('adjustment_requests')
        .where('status', isEqualTo: 'unread')
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  Future<List<Map<String, dynamic>>> getAllAdjustmentRequests() async {
    final snap = await _db.collection('adjustment_requests').get();

    final requests =
        snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    requests.sort((a, b) => compareChatMessages(b, a));
    return requests;
  }

  Stream<List<Map<String, dynamic>>> watchAdjustmentRequestsForUser(
      String userId) {
    return _db
        .collection('adjustment_requests')
        .where('user_id', isEqualTo: userId)
        .snapshots()
        .map((snap) {
      final requests =
          snap.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
      requests.sort(compareChatMessages);
      return requests;
    });
  }

  Stream<List<Map<String, dynamic>>> watchCurrentUserAdjustmentRequests() {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.error(Exception('Usuário não logado'));
    }
    return watchAdjustmentRequestsForUser(user.uid);
  }

  Future<void> markAdjustmentAsRead(String requestId) async {
    await _db
        .collection('adjustment_requests')
        .doc(requestId)
        .update({'status': 'read'});
  }

  Future<void> updateAdjustmentMessage(
      String requestId, String newMessage) async {
    await _db.collection('adjustment_requests').doc(requestId).update({
      'message': newMessage,
      'edited_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> deleteAdjustmentRequest(String requestId,
      {String? audioUrl}) async {
    if (audioUrl != null) {
      try {
        await _storage.refFromURL(audioUrl).delete();
      } catch (e) {
        debugPrint('Erro ao deletar áudio do storage: $e');
      }
    }
    await _db.collection('adjustment_requests').doc(requestId).delete();
  }

  // --- MÉTODOS DE AUTH ---

  /// Senha padrao do primeiro acesso (norma da empresa). Nao vale como a
  /// senha definitiva que a pessoa cria.
  static const String legacyDefaultPassword = '123456';

  /// Login pelo CPF: o backend confere a senha e devolve o e-mail da conta
  /// no Firebase (o de verdade ou o interno do CPF), e o login segue por ele.
  /// Com "@" no [loginId], entra direto pelo e-mail: serve de reserva para o
  /// admin com o backend fora do ar.
  Future<Map<String, dynamic>> loginWithCpf(
      String loginId, String password) async {
    final value = loginId.trim();
    if (value.contains('@')) return login(value, password);

    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$backendUrl/auth/cpf-login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'cpf': cpfDigits(value), 'password': password}),
          )
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      if (isNetworkFailure(e)) {
        throw Exception('Sem conexão com o servidor. Confira a internet e '
            'tente de novo.');
      }
      rethrow;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    final email = (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['email']
        ?.toString();
    if (email == null || email.isEmpty) {
      throw Exception('Resposta inválida do servidor.');
    }
    return login(email, password);
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      // 1. Tentar Login no Firebase Auth
      UserCredential result = await _auth.signInWithEmailAndPassword(
          email: email, password: password);

      if (result.user == null) {
        throw Exception('Firebase Auth: Usuário nulo após login.');
      }

      // 2. Buscar documento no Firestore
      DocumentSnapshot userDoc =
          await _db.collection('users').doc(result.user!.uid).get();

      // Quem cadastra e o admin: conta sem cadastro (criada fora do painel)
      // nao entra. Antes o app criava um cadastro basico aqui.
      if (!userDoc.exists) {
        await _auth.signOut();
        throw Exception(
            'Cadastro não encontrado. Procure o administrador.');
      }
      final userData = userDoc.data() as Map<String, dynamic>;

      final String? token = await result.user!.getIdToken();

      final response = {
        'access_token': token,
        'user': {'id': result.user!.uid, ...userData}
      };
      await _cacheCurrentUser(
          Map<String, dynamic>.from(response['user'] as Map));
      return response;
    } on FirebaseAuthException catch (e) {
      // Mapeamento de erros amigáveis para o usuário
      String errorMessage;
      switch (e.code) {
        case 'user-not-found':
          errorMessage = 'E-mail não cadastrado.';
          break;
        case 'wrong-password':
          errorMessage = 'Senha incorreta.';
          break;
        case 'invalid-email':
          errorMessage = 'Formato de e-mail inválido.';
          break;
        case 'user-disabled':
          errorMessage = 'Esta conta foi desativada.';
          break;
        case 'too-many-requests':
          errorMessage = 'Muitas tentativas. Aguarde um momento.';
          break;
        case 'invalid-credential':
          errorMessage = 'E-mail ou senha incorretos.';
          break;
        default:
          errorMessage = 'Erro de Autenticação (${e.code}): ${e.message}';
      }
      throw Exception(errorMessage);
    } on Exception {
      rethrow;
    } catch (e) {
      // Erro genérico
      throw Exception('Falha ao processar login: $e');
    }
  }

  Future<void> saveLastLogin(String loginId) async {
    final value = loginId.trim();
    if (value.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastLoginKey, value);
    } catch (e) {
      debugPrint('Nao deu para lembrar o login: $e');
    }
  }

  /// Ultimo CPF (ou e-mail) usado no login neste aparelho. Para quem entrou
  /// antes do login por CPF, o CPF do perfil guardado e, sem ele, o e-mail
  /// do login antigo.
  Future<String?> getLastLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_lastLoginKey);
      if (saved != null && saved.isNotEmpty) return saved;
      final cachedCpf = cpfDigits((await getCachedCurrentUser())?['cpf']);
      if (cachedCpf.length == 11) return formatCpf(cachedCpf);
      final legacyEmail = prefs.getString(_lastLoginEmailKey);
      return (legacyEmail == null || legacyEmail.isEmpty) ? null : legacyEmail;
    } catch (e) {
      return null;
    }
  }

  /// Troca a senha da propria conta (no primeiro acesso, obrigatorio), pelo
  /// backend, e entra de novo com ela: a troca pelo Admin SDK pode derrubar
  /// a sessao atual na proxima renovacao do token.
  ///
  /// Fora do primeiro acesso o backend exige [currentPassword]; sem ela
  /// responde 400 "Informe a senha atual".
  Future<void> changeOwnPassword(String newPassword,
      {String? currentPassword}) async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/me/password'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'new_password': newPassword,
            if (currentPassword != null && currentPassword.isNotEmpty)
              'current_password': currentPassword,
          }),
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    final email = _auth.currentUser?.email;
    if (email != null && email.isNotEmpty) {
      try {
        await _auth.signInWithEmailAndPassword(
            email: email, password: newPassword);
      } catch (e) {
        debugPrint('Senha trocada; novo login fica para a proxima abertura: $e');
      }
    }
    final cached = await getCachedCurrentUser();
    if (cached != null) {
      await _cacheCurrentUser({...cached, 'must_change_password': false});
    }
  }

  Future<Map<String, dynamic>> getCurrentUser() async {
    final user = _auth.currentUser;
    if (user != null && await _hasNetworkConnection()) {
      try {
        final currentUser =
            await _getCurrentUserOnline().timeout(const Duration(seconds: 10));
        await _cacheCurrentUser(currentUser);
        return currentUser;
      } catch (e) {
        debugPrint('Perfil online indisponivel, usando cache local: $e');
      }
    }

    final cachedUser = await getCachedCurrentUser();
    if (cachedUser != null &&
        (user == null || cachedUser['id']?.toString() == user.uid)) {
      return cachedUser;
    }

    throw Exception('Perfil do usuario nao encontrado neste aparelho.');
  }

  Future<Map<String, dynamic>> _getCurrentUserOnline() async {
    User? user = _auth.currentUser;
    if (user == null) throw Exception('Nenhum usuário logado');
    DocumentSnapshot doc = await _db.collection('users').doc(user.uid).get();
    if (doc.exists) {
      return {'id': user.uid, ...doc.data() as Map<String, dynamic>};
    }
    throw Exception('Perfil do usuário não encontrado');
  }

  Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedUserKey);
    await _auth.signOut();
  }

  /// Link de nova senha por CPF ou e-mail. Vai pelo backend: o
  /// sendPasswordResetEmail do Firebase dava "enviado" mesmo sem conta com o
  /// e-mail (conta por CPF usa e-mail interno) e o remetente caia no spam.
  /// Devolve a mensagem para mostrar.
  Future<String> resetPassword(String loginId) async {
    final value = loginId.trim();
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$backendUrl/auth/password-reset'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(
                {'login': value.contains('@') ? value : cpfDigits(value)}),
          )
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      if (isNetworkFailure(e)) {
        throw Exception('Sem conexão com o servidor. Confira a internet e '
            'tente de novo.');
      }
      rethrow;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    return (jsonDecode(utf8.decode(response.bodyBytes)) as Map)['message']
            ?.toString() ??
        'Link enviado. Confira sua caixa de entrada e o spam.';
  }

  Future<List<Map<String, dynamic>>> getOfflineRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final rawRecords = prefs.getStringList(_offlineRecordsKey) ?? [];

    return rawRecords
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .toList();
  }

  /// Usuario logado neste aparelho: a sessao do Firebase ou, sem ela, o perfil
  /// guardado.
  Future<String?> _localUserId() async {
    final uid = _auth.currentUser?.uid ??
        (await getCachedCurrentUser())?['id']?.toString();
    return (uid == null || uid.isEmpty) ? null : uid;
  }

  /// Fila offline so do usuario logado. A fila e do aparelho e guarda pontos
  /// de todos que entraram nele; a contagem e o "Descartar" da tela de ponto
  /// valem so para os pontos de quem esta usando.
  Future<List<Map<String, dynamic>>> getCurrentUserOfflineRecords() async {
    final userId = await _localUserId();
    if (userId == null) return [];
    return (await getOfflineRecords())
        .where((record) => record['user_id']?.toString() == userId)
        .toList();
  }

  Future<void> clearCurrentUserOfflineRecords() async {
    final userId = await _localUserId();
    if (userId == null) return;
    final others = (await getOfflineRecords())
        .where((record) => record['user_id']?.toString() != userId)
        .toList();
    await _replaceOfflineRecords(others);
  }

  /// Descarta so as batidas do usuario logado que o servidor recusou. As que
  /// ainda esperam internet ficam: apagar tudo levava junto a entrada de hoje,
  /// boa, so porque a saida de ontem tinha sido recusada.
  Future<void> clearCurrentUserBlockedOfflineRecords() async {
    final userId = await _localUserId();
    if (userId == null) return;
    final kept = (await getOfflineRecords())
        .where((record) =>
            record['user_id']?.toString() != userId ||
            !isBlockedOfflineRecord(record))
        .toList();
    await _replaceOfflineRecords(kept);
  }

  /// Chave de um ponto na fila: o id, ou o proprio JSON nos antigos sem id.
  String _offlineQueueKey(Map<String, dynamic> record) {
    final id = record['id']?.toString() ?? '';
    return id.isNotEmpty ? id : jsonEncode(record);
  }

  String? _offlineQueueKeyOfRaw(String raw) {
    try {
      return _offlineQueueKey(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveOfflineRecord(Map<String, dynamic> recordData) async {
    final prefs = await SharedPreferences.getInstance();
    final records = prefs.getStringList(_offlineRecordsKey) ?? [];
    // Mesmo id = mesma batida (id fixo da pausa automatica, ou a batida que
    // ja estava na fila): nao entra duas vezes.
    final key = _offlineQueueKey(recordData);
    if (records.any((raw) => _offlineQueueKeyOfRaw(raw) == key)) return;
    records.add(jsonEncode(recordData));
    await prefs.setStringList(_offlineRecordsKey, records);
  }

  /// Tira da fila so os pontos [syncedKeys], lendo a fila de AGORA: um ponto
  /// batido enquanto a sincronizacao (lenta, sinal ruim) rodava entrou depois
  /// da copia lida no inicio dela, e regravar aquela copia o apagava. Sem
  /// await entre ler e gravar, nada entra no meio.
  Future<void> _removeOfflineRecords(Set<String> syncedKeys) async {
    if (syncedKeys.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final remaining = (prefs.getStringList(_offlineRecordsKey) ?? [])
        .where((raw) => !syncedKeys.contains(_offlineQueueKeyOfRaw(raw)))
        .toList();
    await prefs.setStringList(_offlineRecordsKey, remaining);
  }

  Future<void> _replaceOfflineRecords(
      List<Map<String, dynamic>> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _offlineRecordsKey,
      records.map((record) => jsonEncode(record)).toList(),
    );
  }

  /// Descarta a fila offline local. Escape para registros que nunca
  /// sincronizam (ex.: entrada de estagiario fora da janela) e ficam
  /// reaparecendo a cada leitura.
  Future<void> clearOfflineRecords() async {
    await _replaceOfflineRecords([]);
  }

  /// Id novo de documento de time_records, gerado no aparelho (sem rede).
  String newTimeRecordId() => _db.collection('time_records').doc().id;

  static final RegExp _clientRecordIdPattern = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

  // Sincronizacao em andamento, compartilhada pelas instancias do ApiService
  // (cada tela cria a sua): duas ao mesmo tempo reenviariam os mesmos pontos.
  static Future<int>? _offlineSyncInFlight;

  /// [retryBlocked]: reenvia tambem as batidas que o servidor ja recusou
  /// (o toque em "Sincronizar"; ex.: o gestor liberou a hora extra depois).
  Future<int> syncOfflineRecords({bool retryBlocked = false}) {
    return _offlineSyncInFlight ??= _syncOfflineRecords(retryBlocked)
        .whenComplete(() => _offlineSyncInFlight = null);
  }

  /// Espera a sincronizacao em andamento, se houver, terminar.
  static Future<void> waitForOfflineSync() async {
    try {
      await _offlineSyncInFlight;
    } catch (_) {
      // O erro ja foi tratado por quem disparou a sincronizacao.
    }
  }

  /// Batida da fila que o servidor recusou pelas regras (precisa de
  /// liberacao, fora do periodo aceito...). Reenviar igual a cada minuto nao
  /// muda nada: ela fica parada, fora da tela de ponto, ate a pessoa tocar em
  /// "Sincronizar" ou descartar.
  static bool isBlockedOfflineRecord(Map<String, dynamic> record) =>
      record['sync_status'] == 'blocked';

  /// Recusada so porque faltava a liberacao do gestor (a saida depois do
  /// limite da hora extra): liberada, a mesma batida passa e nao deve ser
  /// batida de novo.
  static bool isAwaitingApprovalOfflineRecord(Map<String, dynamic> record) =>
      isBlockedOfflineRecord(record) &&
      record['sync_awaiting_approval'] == true;

  /// O reenvio das saidas que esperavam a liberacao teve resposta do
  /// servidor? [before] e [after] sao a fila antes e depois dele. Sim quando
  /// a saida saiu da fila ou quando o servidor recusou de novo algum ponto
  /// (sync_refused_at novo): a propria saida ou um anterior, que a segura.
  /// Com a saida parada na mesma hora de recusa e nenhuma recusa nova, o
  /// reenvio nao chegou ao servidor (timeout no sinal fraco, ou outra
  /// sincronizacao sem reenvio ja rodava) e precisa de outra tentativa.
  static bool awaitingApprovalRetryAnswered(
      List<Map<String, dynamic>> before, List<Map<String, dynamic>> after) {
    String idOf(Map<String, dynamic> record) => record['id']?.toString() ?? '';
    Map<String, String?> refusals(List<Map<String, dynamic>> queue) => {
          for (final record in queue.where(isBlockedOfflineRecord))
            idOf(record): record['sync_refused_at']?.toString(),
        };
    final was = refusals(before);
    final now = refusals(after);
    if (now.entries.any((entry) =>
        !was.containsKey(entry.key) || was[entry.key] != entry.value)) {
      return true;
    }
    return !before.any((record) =>
        record['record_type'] == 'check_out' &&
        isAwaitingApprovalOfflineRecord(record) &&
        now.containsKey(idOf(record)) &&
        now[idOf(record)] == was[idOf(record)]);
  }

  /// Primeiro horario (timestamp) de uma saida recusada em [records], ou
  /// null. O turno dela segue aberto no servidor e o que vem depois na fila
  /// espera por ela.
  static String? firstBlockedCheckOutTimestamp(
      Iterable<Map<String, dynamic>> records) {
    String? first;
    for (final record in records) {
      if (!isBlockedOfflineRecord(record) ||
          record['record_type'] != 'check_out') {
        continue;
      }
      final timestamp = record['timestamp']?.toString() ?? '';
      if (first == null || timestamp.compareTo(first) < 0) first = timestamp;
    }
    return first;
  }

  /// Descarta da fila os pontos [ids] do usuario logado (ex.: a saida
  /// recusada de um turno que foi fechado de outro jeito, no FECHAR PONTO do
  /// horario programado). Mantida, ela seria recusada de novo ("Nao existe
  /// turno aberto") e seguraria os pontos seguintes.
  Future<void> discardCurrentUserOfflineRecords(Set<String> ids) async {
    final userId = await _localUserId();
    if (userId == null || ids.isEmpty) return;
    final kept = (await getOfflineRecords())
        .where((record) =>
            record['user_id']?.toString() != userId ||
            !ids.contains(record['id']?.toString()))
        .toList();
    await _replaceOfflineRecords(kept);
  }

  /// O ponto ainda esta na fila? O "Descartar" pode te-lo tirado enquanto
  /// esta sincronizacao rodava com a copia lida no inicio; enviar assim mesmo
  /// gravava no servidor o ponto que a pessoa mandou jogar fora.
  Future<bool> _isStillQueued(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_offlineRecordsKey) ?? [])
        .any((raw) => _offlineQueueKeyOfRaw(raw) == key);
  }

  /// Marca na fila de AGORA (como _removeOfflineRecords) as batidas recusadas,
  /// com o motivo para a tela mostrar e a hora da recusa (sync_refused_at):
  /// igual depois de um reenvio, ele nao chegou ao servidor.
  Future<void> _markOfflineRecordsBlocked(
      Map<String, PunchRejectedException> reasons) async {
    if (reasons.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final updated = (prefs.getStringList(_offlineRecordsKey) ?? []).map((raw) {
      final reason = reasons[_offlineQueueKeyOfRaw(raw)];
      if (reason == null) return raw;
      final record = jsonDecode(raw) as Map<String, dynamic>;
      return jsonEncode({
        ...record,
        'sync_status': 'blocked',
        'sync_error': reason.message,
        'sync_awaiting_approval': reason.awaitingApproval,
        'sync_refused_at': DateTime.now().toIso8601String(),
      });
    }).toList();
    await prefs.setStringList(_offlineRecordsKey, updated);
  }

  Future<int> _syncOfflineRecords(bool retryBlocked) async {
    // A fila e do aparelho. Ponto de outro usuario que usou este celular fica
    // nela ate ele entrar de novo: com a sessao deste, a escrita direta falha
    // nas regras e o backend gravaria a batida em nome de quem esta logado.
    final userId = _auth.currentUser?.uid;
    if (userId == null) return 0;
    // Em ordem de horario: cada batida depende do estado que as anteriores
    // deixam no servidor (a saida precisa da entrada; o backend confere o
    // turno aberto no momento da batida). sort e estavel: mesmo horario
    // fica na ordem da fila.
    final pendingRecords = (await getOfflineRecords())
        .where((record) => record['user_id']?.toString() == userId)
        .toList()
      ..sort((a, b) => (a['timestamp']?.toString() ?? '')
          .compareTo(b['timestamp']?.toString() ?? ''));
    if (pendingRecords.isEmpty) return 0;
    final cachedUser = await getCachedCurrentUser();
    final profile = cachedUser?['id']?.toString() == userId
        ? cachedUser!
        : await getCurrentUser();
    // Mesma regra do backend: papel ou cargo "Estagiario".
    final isIntern = isInternProfile(profile);

    int syncedCount = 0;
    final syncedKeys = <String>{};
    final blockedReasons = <String, PunchRejectedException>{};

    // A primeira batida que nao entra (recusada, parada ou falha de rede)
    // segura as seguintes na fila, pendentes. Seguir em frente mandava a
    // saida sem a entrada: o backend recusava com "Nao existe turno aberto",
    // a saida ficava parada para sempre e as pausas iam direto para o
    // servidor, soltas, sem o turno delas.
    for (final record in pendingRecords) {
      final recordId = record['id']?.toString() ?? '';
      final key = _offlineQueueKey(record);
      if (isBlockedOfflineRecord(record) && !retryBlocked) break;
      if (!await _isStillQueued(key)) continue;
      try {
        final recordType = record['record_type']?.toString() ?? '';
        if (isIntern &&
            (recordType == 'check_in' || recordType == 'check_out')) {
          final result = await createScheduleControlledPunch(
            recordType: recordType,
            timestamp: record['timestamp']?.toString(),
            location: record['location']?.toString(),
            notes: record['notes']?.toString(),
            latitude: (record['latitude'] as num?)?.toDouble(),
            longitude: (record['longitude'] as num?)?.toDouble(),
            // Mesmo id da batida original: se ela chegou ao backend antes de
            // a rede cair, o reenvio devolve o ponto gravado em vez de
            // duplicar (ou de recusar com "Ja existe um turno aberto").
            clientRecordId:
                _clientRecordIdPattern.hasMatch(recordId) ? recordId : null,
            offline: true,
            // FECHAR PONTO no horario programado guardado sem internet: segue
            // como fechamento, nao como saida comum. Como saida comum, com o
            // "Bloquear tela apos" igual ao fim do horario, ela pedia
            // liberacao e ficava parada.
            closeAtScheduledEnd: record['close_at_scheduled_end'] == true,
          );
          if (result['status'] == 'approval_required') {
            // A saida depois do limite passa com a liberacao da hora extra. A
            // entrada fora do horario nao: a liberacao grava a propria entrada,
            // na hora do pedido feito pela tela.
            throw PunchRejectedException('Depende de liberacao do gestor.',
                awaitingApproval: result['request_type'] == 'overtime');
          }
        } else {
          if (recordId.isEmpty) {
            // Formato antigo, sem id: gravar duplicaria a cada tentativa. Fica
            // na fila (o Descartar tira) sem segurar as outras.
            debugPrint('Registro offline sem identificador.');
            continue;
          }
          // Pelo backend, com a hora do aparelho no momento da batida (no
          // maximo 7 dias). A entrada com um turno velho aberto antes dela
          // fecha esse turno como saida esquecida la (o app fazia isso
          // gravando direto no Firestore).
          await _cacheSentRecord(await _sendPunch(record, offline: true));
        }
        syncedCount++;
        syncedKeys.add(key);
      } on PunchRejectedException catch (e) {
        // So os que tem id: sem ele a chave e o proprio JSON, que muda ao
        // marcar.
        if (recordId.isNotEmpty) blockedReasons[key] = e;
        debugPrint('Ponto offline $recordId recusado: ${e.message}');
        break;
      } catch (e) {
        debugPrint('Erro ao sincronizar ponto offline $recordId: $e');
        break;
      }
    }

    await _removeOfflineRecords(syncedKeys);
    await _markOfflineRecordsBlocked(blockedReasons);
    return syncedCount;
  }

  // Calculo da folha (arredondamento, feriados, turnos e classificacao das
  // horas): utils/timesheet.dart.

  // --- MÉTODOS DE DADOS ---

  /// Batida da propria pessoa ([userId] nulo): vai pelo backend
  /// (/time-records/punch), que vale a hora do servidor online e no maximo 7
  /// dias de atraso offline. Sem internet ou com o backend fora, entra na fila
  /// offline e a sincronizacao reenvia pelo mesmo endpoint. Antes gravava
  /// direto no Firestore com a hora do celular, e as regras aceitavam ponto
  /// com qualquer horario.
  ///
  /// [punchKind]: "forgotten_exit" (fecha o turno [refRecordId] sem horas) ou
  /// "auto_break_close" (fecha a pausa [refRecordId], aberta ha 3h+, com 1h).
  /// O servidor calcula a hora e o id dessas; [timestamp] so serve para a
  /// tela enquanto a batida espera na fila.
  ///
  /// [userId] (lote do gestor, inclusive para o proprio gestor): grava direto
  /// no Firestore, que as regras so permitem a admin e gestor. [extraFields]
  /// entra junto nesse caso.
  Future<Map<String, dynamic>> createTimeRecord({
    required String recordType,
    String? location,
    String? notes,
    String? timestamp,
    String? userId,
    double? latitude,
    double? longitude,
    String? punchKind,
    String? refRecordId,
    Map<String, dynamic>? extraFields,
  }) async {
    final currentUser = _auth.currentUser;
    final cachedUser = await getCachedCurrentUser();
    final currentUserId = currentUser?.uid ?? cachedUser?['id']?.toString();
    if (currentUserId == null || currentUserId.isEmpty) {
      throw Exception(
          'Faca login com internet uma vez antes de registrar offline.');
    }
    final now = DateTime.now();
    final recordTimestamp = timestamp ?? now.toIso8601String();

    if (userId != null) {
      final recordData = {
        'user_id': userId,
        'record_type': recordType,
        'location': location ?? 'App',
        'notes': notes,
        'timestamp': recordTimestamp,
        'latitude': latitude,
        'longitude': longitude,
        if (userId != currentUserId) 'created_by_admin': true,
        ...?extraFields,
      };
      final docRef = _db.collection('time_records').doc();
      await docRef.set({
        ...recordData,
        'created_at': FieldValue.serverTimestamp(),
      }).timeout(const Duration(seconds: 10));
      if (userId == currentUserId) {
        await _appendCachedTimeRecord(
            currentUserId, {'id': docRef.id, ...recordData});
      }
      return {'id': docRef.id, ...recordData};
    }

    // Id gerado ANTES do envio: se a resposta se perder, o reenvio da fila
    // com o mesmo id devolve o ponto gravado em vez de duplicar.
    final punch = <String, dynamic>{
      'id': newTimeRecordId(),
      'user_id': currentUserId,
      'record_type': recordType,
      'location': location ?? 'App',
      'notes': notes,
      'timestamp': recordTimestamp,
      'latitude': latitude,
      'longitude': longitude,
      if (punchKind != null) 'punch_kind': punchKind,
      if (refRecordId != null) 'ref_record_id': refRecordId,
    };
    if (currentUser != null && await _hasNetworkConnection()) {
      try {
        final result = await _sendPunch(punch, offline: false);
        await _cacheSentRecord(result);
        return result;
      } catch (e) {
        // Recusa do servidor (turno ja aberto...) aparece na tela; so a falta
        // de rede ou o backend fora do ar vao para a fila.
        if (!isNetworkFailure(e)) rethrow;
        debugPrint('Backend inacessivel, guardando ponto na fila: $e');
      }
    }
    final offlineRecord = {
      ...punch,
      'offline': true,
      'sync_status': 'pending',
      'created_at_local': now.toIso8601String(),
    };
    await _saveOfflineRecord(offlineRecord);
    debugPrint(
        'Ponto salvo offline para sincronizar depois: ${offlineRecord['id']}');
    return offlineRecord;
  }

  /// Envia [punch] (formato da fila) a /time-records/punch. Recusa da regra:
  /// PunchRejectedException. Backend fora: ServerUnavailableException.
  Future<Map<String, dynamic>> _sendPunch(Map<String, dynamic> punch,
      {required bool offline}) async {
    final id = punch['id']?.toString() ?? '';
    // Fila antiga (antes do backend): o tipo especial vinha so no id.
    var kind = punch['punch_kind']?.toString();
    var ref = punch['ref_record_id']?.toString();
    for (final prefix in const {
      'autoclose_': 'auto_break_close',
      'forgot_': 'forgotten_exit'
    }.entries) {
      if (kind == null && id.startsWith(prefix.key)) {
        kind = prefix.value;
        ref = id.substring(prefix.key.length);
      }
    }
    final response = await http
        .post(
          Uri.parse('$backendUrl/time-records/punch'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'record_type': punch['record_type'],
            'client_record_id':
                _clientRecordIdPattern.hasMatch(id) ? id : newTimeRecordId(),
            'timestamp': punch['timestamp'],
            'offline': offline,
            'location': punch['location'],
            'notes': punch['notes'],
            'latitude': (punch['latitude'] as num?)?.toDouble(),
            'longitude': (punch['longitude'] as num?)?.toDouble(),
            if (kind != null) 'kind': kind,
            if (ref != null) 'ref_record_id': ref,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404 || response.statusCode >= 500) {
      throw ServerUnavailableException(_apiError(response));
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 401, 403, 408 e 429 podem passar na proxima tentativa; o resto dos
      // 4xx e a regra recusando a batida.
      if (const {401, 403, 408, 429}.contains(response.statusCode)) {
        throw Exception(_apiError(response));
      }
      throw PunchRejectedException(_apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  /// Guarda o ponto na fila local SEM tentar o servidor.
  ///
  /// Usado quando a rede caiu no meio de uma batida que exige validacao do
  /// backend (estagiario). Nao escreve direto no Firestore de proposito: a
  /// sincronizacao reenvia pelo /work-schedule/punch, que aplica as regras de
  /// horario, quando a internet voltar.
  ///
  /// [id]: o mesmo id ja mandado ao backend na tentativa que falhou. Se ela
  /// chegou a gravar antes de a resposta se perder, o reenvio devolve esse
  /// ponto em vez de criar outro.
  ///
  /// [closeAtScheduledEnd]: e o FECHAR PONTO no horario programado; a
  /// sincronizacao o reenvia como fechamento.
  Future<Map<String, dynamic>> queueTimeRecordOffline({
    required String recordType,
    String? location,
    String? notes,
    String? timestamp,
    double? latitude,
    double? longitude,
    String? id,
    bool closeAtScheduledEnd = false,
  }) async {
    final cachedUser = await getCachedCurrentUser();
    final userId = _auth.currentUser?.uid ?? cachedUser?['id']?.toString();
    if (userId == null || userId.isEmpty) {
      throw Exception(
          'Faca login com internet uma vez antes de registrar offline.');
    }

    final now = DateTime.now();
    final offlineRecord = <String, dynamic>{
      'id': id ?? newTimeRecordId(),
      'user_id': userId,
      'record_type': recordType,
      'location': location ?? 'App',
      'notes': notes,
      'timestamp': timestamp ?? now.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      if (closeAtScheduledEnd) 'close_at_scheduled_end': true,
      'offline': true,
      'sync_status': 'pending',
      'created_at_local': now.toIso8601String(),
    };
    await _saveOfflineRecord(offlineRecord);
    debugPrint('Ponto guardado na fila offline: ${offlineRecord['id']}');
    return offlineRecord;
  }

  /// Erro de rede (sem sinal, DNS, timeout), em oposicao a uma resposta do
  /// servidor recusando o pedido.
  static bool isNetworkFailure(Object error) {
    if (error is TimeoutException ||
        error is http.ClientException ||
        error is ServerUnavailableException) {
      return true;
    }
    // Sem sinal, a renovacao do token (expira em 1h) falha antes de qualquer
    // pedido HTTP: era o caso mais comum de batida offline do estagiario, e
    // ela se perdia em vez de entrar na fila.
    if (error is FirebaseException &&
        (error.code == 'network-request-failed' ||
            error.code == 'unavailable')) {
      return true;
    }
    final text = error.toString();
    return text.contains('network-request-failed') ||
        text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection refused') ||
        text.contains('Network is unreachable');
  }

  // ignore: unused_element
  Future<Map<String, dynamic>> _createTimeRecordLegacy({
    required String recordType,
    String? location,
    String? notes,
    String? timestamp,
    String? userId,
    double? latitude,
    double? longitude,
  }) async {
    User? currentUser = _auth.currentUser;
    if (currentUser == null) throw Exception('Usuário não autenticado');

    final targetUid = userId ?? currentUser.uid;

    final now = DateTime.now();
    final recordTimestamp = timestamp ?? now.toIso8601String();
    final recordData = {
      'user_id': targetUid,
      'record_type': recordType,
      'location': location ?? 'App',
      'notes': notes,
      'timestamp': recordTimestamp,
      'latitude': latitude,
      'longitude': longitude,
      if (userId != null && userId != currentUser.uid) 'created_by_admin': true,
    };

    try {
      DocumentReference docRef = await _db.collection('time_records').add({
        ...recordData,
        'created_at': FieldValue.serverTimestamp(),
      });
      return {'id': docRef.id, ...recordData};
    } catch (e) {
      if (userId != null && userId != currentUser.uid) {
        rethrow;
      }

      final offlineRecord = {
        'id': 'offline_${now.microsecondsSinceEpoch}',
        ...recordData,
        'offline': true,
        'sync_status': 'pending',
        'created_at_local': now.toIso8601String(),
      };
      await _saveOfflineRecord(offlineRecord);
      debugPrint(
          'Ponto salvo offline para sincronizar depois: ${offlineRecord['id']}');
      return offlineRecord;
    }
  }

  /// [localOnly]: nao consulta o servidor; usa so a copia local e a fila
  /// offline. Serve para a tela abrir na hora, antes da atualizacao online.
  Future<List<dynamic>> getTimeRecords(
      {String? startDate,
      String? endDate,
      String? userId,
      bool localOnly = false}) async {
    final cachedUser = await getCachedCurrentUser();
    final currentUserId =
        _auth.currentUser?.uid ?? cachedUser?['id']?.toString();
    final targetUid = userId ?? currentUserId;
    var records = <Map<String, dynamic>>[];

    // Consulta com filtro de data no Firestore: le so a janela pedida, nao o
    // historico inteiro. Reduz drasticamente as leituras (chave para caber na
    // cota). Exige indice composto user_id + timestamp (firestore.indexes.json).
    Query<Map<String, dynamic>> query =
        _db.collection('time_records').where('user_id', isEqualTo: targetUid);
    if (startDate != null) {
      query = query.where('timestamp', isGreaterThanOrEqualTo: startDate);
    }
    if (endDate != null) {
      query = query.where('timestamp', isLessThanOrEqualTo: endDate);
    }

    final ownUid = (targetUid != null && targetUid == currentUserId)
        ? targetUid
        : null;
    var fromServer = false;
    final online = !localOnly && await _hasNetworkConnection();

    if (online) {
      try {
        final snapshot = await query.get().timeout(const Duration(seconds: 10));
        records =
            snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
        fromServer = true;
      } catch (e) {
        // Sem o indice composto (FAILED_PRECONDITION) ou outra falha: cai para a
        // consulta simples por usuario. Le mais, mas nao quebra; o filtro de data
        // em memoria abaixo garante o mesmo resultado.
        debugPrint('Consulta por data indisponivel, usando fallback: $e');
        try {
          final snapshot = await _db
              .collection('time_records')
              .where('user_id', isEqualTo: targetUid)
              .get()
              .timeout(const Duration(seconds: 10));
          records =
              snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
          fromServer = true;
        } catch (e2) {
          debugPrint('Pontos online indisponiveis, usando registros offline: $e2');
        }
      }
    }

    if (ownUid != null) {
      if (fromServer) {
        await _cacheTimeRecords(ownUid, startDate, endDate, records);
      } else {
        records = await _readCachedTimeRecords(ownUid);
      }
    }

    if (targetUid == currentUserId) {
      // Um registro da fila offline pode ja ter chegado ao servidor (a escrita
      // continua em background depois do timeout). Como ambos usam o mesmo id,
      // ignorar os que ja vieram do Firestore evita mostrar o ponto em dobro.
      final knownIds = records.map((record) => record['id']).toSet();
      final offlineRecords = (await getOfflineRecords())
          .where((record) => record['user_id'] == targetUid)
          .toList();
      // A recusada pelo servidor fica de fora: com ela na lista, a tela
      // seguia mostrando o turno fechado (ou aberto) que o servidor nao tem, e
      // a pessoa nao conseguia bater de novo nem pedir a liberacao.
      // Depois de uma saida recusada, o turno dela segue aberto no servidor e
      // o resto da fila espera por ela: a entrada e a saida do dia seguinte,
      // ainda na fila, fechavam a conta na tela e o turno aberto sumia (sem
      // tela de hora extra, sem FECHAR PONTO, sem pedir a liberacao).
      final heldFrom = firstBlockedCheckOutTimestamp(offlineRecords);
      records.addAll(offlineRecords.where((record) =>
          !knownIds.contains(record['id']) &&
          !isBlockedOfflineRecord(record) &&
          (heldFrom == null ||
              (record['timestamp']?.toString() ?? '').compareTo(heldFrom) <
                  0)));
    }

    // Do mais novo para o mais antigo; no mesmo horario, a ordem vem do
    // tipo (sortRecords), como no calculo do turno.
    records = sortRecords(records).reversed.toList();
    if (startDate != null || endDate != null) {
      records = records.where((record) {
        final timestamp = record['timestamp'] as String;
        var matches = true;
        if (startDate != null) {
          matches = matches && timestamp.compareTo(startDate) >= 0;
        }
        if (endDate != null) {
          matches = matches && timestamp.compareTo(endDate) <= 0;
        }
        return matches;
      }).toList();
    }

    return records;
  }

  /// Atualiza a copia local com o que o servidor devolveu para a janela
  /// [startDate, endDate]: dentro da janela o servidor manda (inclusive
  /// remocoes); fora dela a copia anterior fica. Guarda so os ultimos
  /// [_recordsCacheDays] dias.
  Future<void> _cacheTimeRecords(String uid, String? startDate,
      String? endDate, List<Map<String, dynamic>> serverRecords) async {
    try {
      bool inWindow(String ts) =>
          (startDate == null || ts.compareTo(startDate) >= 0) &&
          (endDate == null || ts.compareTo(endDate) <= 0);
      final cutoff = DateTime.now()
          .subtract(const Duration(days: _recordsCacheDays))
          .toIso8601String();
      final kept = (await _readCachedTimeRecords(uid))
          .where((r) => !inWindow(r['timestamp']?.toString() ?? ''));
      final merged = [
        ...kept,
        ...serverRecords.map(_jsonSafeRecord),
      ]
          .where((r) => (r['timestamp']?.toString() ?? '').compareTo(cutoff) >= 0)
          .toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_recordsCachePrefix$uid', jsonEncode(merged));
    } catch (e) {
      debugPrint('Nao deu para guardar a copia local dos pontos: $e');
    }
  }

  /// True quando este aparelho ja tem a copia local dos pontos do usuario
  /// logado (gravada numa leitura online anterior).
  Future<bool> hasLocalTimeRecordsCache() async {
    final cachedUser = await getCachedCurrentUser();
    final uid = _auth.currentUser?.uid ?? cachedUser?['id']?.toString();
    if (uid == null || uid.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_recordsCachePrefix$uid');
  }

  Future<void> _appendCachedTimeRecord(
      String uid, Map<String, dynamic> record) async {
    try {
      final records = (await _readCachedTimeRecords(uid))
          .where((r) => r['id'] != record['id'])
          .toList()
        ..add(_jsonSafeRecord(record));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_recordsCachePrefix$uid', jsonEncode(records));
    } catch (e) {
      debugPrint('Nao deu para guardar o ponto na copia local: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _readCachedTimeRecords(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_recordsCachePrefix$uid');
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } catch (e) {
      debugPrint('Copia local dos pontos ilegivel: $e');
      return [];
    }
  }

  Map<String, dynamic> _jsonSafeRecord(Map<String, dynamic> record) =>
      record.map((key, value) => MapEntry(key, _jsonSafeValue(value)));

  dynamic _jsonSafeValue(dynamic value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is DateTime) return value.toIso8601String();
    if (value is GeoPoint) {
      return {'latitude': value.latitude, 'longitude': value.longitude};
    }
    if (value is List) return value.map(_jsonSafeValue).toList();
    if (value is Map) {
      return value.map(
          (key, item) => MapEntry(key.toString(), _jsonSafeValue(item)));
    }
    return value.toString();
  }

  // ignore: unused_element
  Future<List<dynamic>> _getTimeRecordsLegacy(
      {String? startDate, String? endDate, String? userId}) async {
    String? targetUid = userId ?? _auth.currentUser?.uid;
    var records = <Map<String, dynamic>>[];

    try {
      QuerySnapshot snapshot = await _db
          .collection('time_records')
          .where('user_id', isEqualTo: targetUid)
          .get();
      records = snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data() as Map<String, dynamic>})
          .toList();
    } catch (e) {
      debugPrint(
          'Erro ao buscar pontos online, usando fila offline se houver: $e');
    }

    if (targetUid == _auth.currentUser?.uid) {
      final offlineRecords = await getOfflineRecords();
      records.addAll(
          offlineRecords.where((record) => record['user_id'] == targetUid));
    }

    // Do mais novo para o mais antigo; no mesmo horario, a ordem vem do
    // tipo (sortRecords), como no calculo do turno.
    records = sortRecords(records).reversed.toList();
    if (startDate != null || endDate != null) {
      records = records.where((r) {
        final ts = r['timestamp'] as String;
        bool match = true;
        if (startDate != null) match = match && ts.compareTo(startDate) >= 0;
        if (endDate != null) match = match && ts.compareTo(endDate) <= 0;
        return match;
      }).toList();
    }
    return records;
  }

  Future<List<dynamic>> getWorkSummary(
      {required String startDate, required String endDate}) async {
    final user = await getCurrentUser();
    final exportData = await exportTimesheet(
        startDate: startDate, endDate: endDate, userId: user['id']);
    return exportData['daily_records'];
  }

  Future<Map<String, dynamic>> exportTimesheet(
      {required String startDate,
      required String endDate,
      dynamic userId}) async {
    Map<String, dynamic> user;
    if (userId != null) {
      DocumentSnapshot doc =
          await _db.collection('users').doc(userId.toString()).get();
      user = {'id': userId.toString(), ...doc.data() as Map<String, dynamic>};
    } else {
      user = await getCurrentUser();
    }

    if (user['daily_mode'] == true) {
      return _timesheetResult(
          user, await _dailyModeWorkDays(user, startDate, endDate));
    }

    // Busca um dia a mais de cada lado: o turno que comeca no ultimo dia do
    // periodo pode fechar no dia seguinte, e o ponto da madrugada do primeiro
    // dia pode ser de um turno da vespera (que fica no periodo anterior).
    final fetchStart = DateTime.parse(startDate)
        .subtract(const Duration(days: 1))
        .toIso8601String();
    final fetchEnd =
        DateTime.parse(endDate).add(const Duration(days: 1)).toIso8601String();
    final firstDay = startDate.substring(0, 10);
    final lastDay = endDate.substring(0, 10);
    final records = await getTimeRecords(
        startDate: fetchStart, endDate: fetchEnd, userId: user['id']);
    // Agrupa pelo dia em que o turno comecou: entrada 19:30 e saida 07:00 sao
    // um turno so, do dia da entrada.
    final grouped = groupRecordsByWorkDay(records)
      ..removeWhere((day, _) =>
          day.compareTo(firstDay) < 0 || day.compareTo(lastDay) > 0);

    // Folha do estagiario pela mesma regra do backend (papel ou cargo):
    // so ele tem as horas fora da janela 13:30-19:30 como extras.
    final role = isInternProfile(user)
        ? 'intern'
        : user['role']?.toString() ?? 'employee';
    return _timesheetResult(user, [
      for (final MapEntry(key: date, value: dayRecords) in grouped.entries)
        computeWorkDay(date, dayRecords, role),
    ]);
  }

  /// Resposta de exportTimesheet: os dias (o mais novo primeiro) e os totais.
  Map<String, dynamic> _timesheetResult(
      Map<String, dynamic> user, List<Map<String, dynamic>> dailyRecords) {
    double totalN = 0, totalE = 0, total50 = 0, total100 = 0;
    for (final day in dailyRecords) {
      final regular = day['regular_hours'] as double;
      final extra50 = day['extra_50'] as double;
      final extra100 = day['extra_100'] as double;
      totalN += regular;
      // Extras de contrato (estagiario fora das 13:30-19:30): o que sobra das
      // horas extras tirando as de 50% e 100%.
      totalE += (day['overtime_hours'] as double) - extra50 - extra100;
      total50 += extra50;
      total100 += extra100;
    }

    dailyRecords
        .sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));

    return {
      'employee': user,
      'summary': {
        'total_hours':
            (totalN + totalE + total50 + total100).toStringAsFixed(1),
        'total_regular_hours': totalN.toStringAsFixed(1),
        'total_extras': totalE.toStringAsFixed(1),
        'total_50': total50.toStringAsFixed(1),
        'total_100': total100.toStringAsFixed(1),
      },
      'daily_records': dailyRecords,
    };
  }

  // --- MODO DIARIA ---
  // Quem esta no modo diaria (users.daily_mode) so marca a diaria do dia, pelo
  // backend: uma por pessoa por dia, no dia do relogio do servidor. Sem
  // internet (ou com o servidor fora do ar) ela fica guardada no aparelho e
  // vai depois, valendo o dia do toque.

  static const String _pendingDailyEntriesKey = 'pending_daily_entries';
  static const String _dailyEntriesCachePrefix = 'cached_daily_entries_';
  // Dias de diarias que a copia local guarda (o periodo da folha e folga).
  static const int _dailyEntriesCacheDays = 62;
  // Envio da fila de diarias em andamento: a volta da internet e o
  // recarregamento da tela chamam juntos.
  static Future<List<Map<String, dynamic>>>? _dailySync;

  static bool _isTemporaryDailyFailure(Object error) =>
      isNetworkFailure(error) ||
      (error is _DailyEntryHttpException && error.temporary);

  Future<Map<String, dynamic>> _postDailyEntry({DateTime? offlineAt}) async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/daily-entries'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            if (offlineAt != null) 'offline': true,
            if (offlineAt != null) 'timestamp': offlineAt.toIso8601String(),
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _DailyEntryHttpException(response.statusCode, _apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  /// Marca a diaria de hoje. 'status' da resposta: 'created', 'existing' (ja
  /// havia diaria hoje, de outro toque ou aparelho) ou 'pending' (guardada
  /// no aparelho; syncPendingDailyEntries envia depois).
  Future<Map<String, dynamic>> addDailyEntry() async {
    final tappedAt = DateTime.now();
    try {
      final entry = await _postDailyEntry();
      await _cacheDailyEntries([entry]);
      return entry;
    } catch (e) {
      if (!_isTemporaryDailyFailure(e)) rethrow;
      debugPrint('Diaria guardada no aparelho para enviar depois: $e');
      return _queueDailyEntry(tappedAt);
    }
  }

  Future<List<Map<String, dynamic>>> _readJsonList(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } catch (e) {
      debugPrint('Lista local ilegivel ($key): $e');
      return [];
    }
  }

  Future<void> _writeJsonList(
      String key, List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(items));
  }

  Future<Map<String, dynamic>> _queueDailyEntry(DateTime at) async {
    final uid = await _localUserId();
    if (uid == null) {
      throw Exception(
          'Faca login com internet uma vez antes de registrar offline.');
    }
    final entry = {
      'user_id': uid,
      'date': dailyDayKey(at),
      'registered_at': at.toIso8601String(),
    };
    final queued = await _readJsonList(_pendingDailyEntriesKey);
    // Uma por dia tambem na fila: outro toque sem internet nao vira outra.
    if (!queued.any((item) =>
        item['user_id'] == uid && item['date'] == entry['date'])) {
      await _writeJsonList(_pendingDailyEntriesKey, [...queued, entry]);
    }
    return {...entry, 'status': 'pending', 'pending': true};
  }

  /// Diarias do usuario logado guardadas no aparelho, ainda nao enviadas.
  Future<List<Map<String, dynamic>>> getPendingDailyEntries() async {
    final uid = await _localUserId();
    return (await _readJsonList(_pendingDailyEntriesKey))
        .where((item) => item['user_id'] == uid)
        .toList();
  }

  Future<void> _removePendingDailyEntry(Map<String, dynamic> entry) async {
    final queued = await _readJsonList(_pendingDailyEntriesKey);
    await _writeJsonList(
        _pendingDailyEntriesKey,
        queued
            .where((item) =>
                item['user_id'] != entry['user_id'] ||
                item['date'] != entry['date'])
            .toList());
  }

  /// Envia as diarias guardadas no aparelho. Devolve as que o servidor
  /// recusou (ex.: mais de 7 dias sem internet), ja fora da fila e com o
  /// motivo em 'sync_error', para a tela avisar. Sem internet ou com o
  /// servidor fora do ar, as diarias continuam guardadas.
  Future<List<Map<String, dynamic>>> syncPendingDailyEntries() =>
      _dailySync ??= _syncPendingDailyEntries()
          .whenComplete(() => _dailySync = null);

  Future<List<Map<String, dynamic>>> _syncPendingDailyEntries() async {
    final rejected = <Map<String, dynamic>>[];
    for (final pending in await getPendingDailyEntries()) {
      final at = DateTime.tryParse(pending['registered_at']?.toString() ?? '');
      try {
        if (at == null) {
          throw const _DailyEntryHttpException(400, 'Diária sem horário.');
        }
        await _cacheDailyEntries([await _postDailyEntry(offlineAt: at)]);
      } catch (e) {
        if (_isTemporaryDailyFailure(e)) break;
        if (e is! _DailyEntryHttpException) {
          debugPrint('Diaria guardada nao enviada: $e');
          break;
        }
        rejected.add({...pending, 'sync_error': e.message});
      }
      await _removePendingDailyEntry(pending);
    }
    return rejected;
  }

  /// Guarda [entries] (do servidor) na copia local do usuario logado. Com
  /// [fromDay] e [toDay], a resposta do servidor manda nesse periodo: o que
  /// a copia tinha nele e nao veio sai.
  Future<void> _cacheDailyEntries(List<Map<String, dynamic>> entries,
      {String? fromDay, String? toDay}) async {
    try {
      final uid = await _localUserId();
      if (uid == null) return;
      bool replaced(String day) =>
          fromDay != null &&
          toDay != null &&
          day.compareTo(fromDay) >= 0 &&
          day.compareTo(toDay) <= 0;
      final key = '$_dailyEntriesCachePrefix$uid';
      final byDay = <String, Map<String, dynamic>>{
        for (final entry in await _readJsonList(key))
          if (!replaced(entry['date']?.toString() ?? ''))
            entry['date'].toString(): entry,
      };
      for (final entry in entries) {
        if (entry['user_id'] != uid || entry['date'] == null) continue;
        byDay[entry['date'].toString()] = _jsonSafeRecord(entry);
      }
      final cutoff = dailyDayKey(DateTime.now()
          .subtract(const Duration(days: _dailyEntriesCacheDays)));
      await _writeJsonList(
          key,
          byDay.values
              .where((entry) => entry['date'].toString().compareTo(cutoff) >= 0)
              .toList());
    } catch (e) {
      debugPrint('Nao deu para guardar a copia local das diarias: $e');
    }
  }

  /// Diarias do usuario logado de [start] a [end] (dias), com as guardadas
  /// no aparelho ('pending': true). Sem internet, ou com [localOnly], vem da
  /// copia local da ultima consulta.
  Future<List<Map<String, dynamic>>> getMyDailyEntries(
      {required DateTime start,
      required DateTime end,
      bool localOnly = false}) async {
    final uid = await _localUserId();
    if (uid == null) return [];
    List<Map<String, dynamic>>? server;
    if (!localOnly) {
      try {
        server = await getDailyEntries(start: start, end: end);
        await _cacheDailyEntries(server,
            fromDay: dailyDayKey(start), toDay: dailyDayKey(end));
      } catch (e) {
        if (!_isTemporaryDailyFailure(e)) rethrow;
        debugPrint('Diarias online indisponiveis, usando a copia local: $e');
      }
    }
    server ??= dailyEntriesBetween(
        await _readJsonList('$_dailyEntriesCachePrefix$uid'), start, end);
    return mergeDailyEntries(server,
        dailyEntriesBetween(await getPendingDailyEntries(), start, end));
  }

  /// Diarias de [userId] (sem ele, do usuario logado) de [start] a [end],
  /// direto do servidor. Outra pessoa: so admin ou gestor.
  Future<List<Map<String, dynamic>>> getDailyEntries(
      {required DateTime start, required DateTime end, String? userId}) async {
    final response = await http
        .get(
          Uri.parse('$backendUrl/daily-entries').replace(queryParameters: {
            'start': dailyDayKey(start),
            'end': dailyDayKey(end),
            if (userId != null) 'user_id': userId,
          }),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _DailyEntryHttpException(response.statusCode, _apiError(response));
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    return [
      for (final entry in (decoded['entries'] as List? ?? const []))
        Map<String, dynamic>.from(entry as Map),
    ];
  }

  /// Dias da folha de quem esta no modo diaria, para os paineis (Dash, Meu
  /// Mes): o dia padrao de cada diaria do periodo (dailyStandardWorkDay), o
  /// mesmo horario da folha exportada. Do proprio usuario entram tambem as
  /// guardadas no aparelho ('pending').
  Future<List<Map<String, dynamic>>> _dailyModeWorkDays(
      Map<String, dynamic> user, String startDate, String endDate) async {
    final start = DateTime.parse(startDate);
    final end = DateTime.parse(endDate);
    final userId = user['id'].toString();
    final entries = userId == await _localUserId()
        ? await getMyDailyEntries(start: start, end: end)
        : await getDailyEntries(start: start, end: end, userId: userId);
    final name = user['name']?.toString() ?? '';
    // Folha do estagiario pela mesma regra do backend (papel ou cargo):
    // so ele tem as horas fora da janela 13:30-19:30 como extras.
    final role = isInternProfile(user)
        ? 'intern'
        : user['role']?.toString() ?? 'employee';
    return [
      for (final entry in entries)
        {
          ...dailyStandardWorkDay(
              name, entry['date'].toString(), user['daily_hours'], role),
          if (entry['pending'] == true) 'pending': true,
        },
    ];
  }

  /// Admin lanca a diaria de [userId] no dia [day] (a pessoa esqueceu de
  /// marcar). Uma por dia; dia futuro nao.
  Future<Map<String, dynamic>> adminAddDailyEntry(
      {required String userId,
      required DateTime day,
      required String reason}) async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/admin/daily-entries'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'user_id': userId,
            'date': dailyDayKey(day),
            'reason': reason,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  /// Admin apaga a diaria [entryId]; a copia fica na auditoria.
  Future<void> adminDeleteDailyEntry(
      {required String entryId, required String reason}) async {
    final response = await http
        .delete(
          Uri.parse(
              '$backendUrl/admin/daily-entries/${Uri.encodeComponent(entryId)}'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'reason': reason}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
  }

  // --- MÉTODOS DE ADMIN ---

  // Cache do quadro de pessoal. A lista muda algumas vezes por mes, mas era
  // relida inteira em toda abertura de tela de gestao (resumo, registros,
  // documentos, dash). Estatico de proposito: cada tela cria seu ApiService.
  static List<dynamic>? _cachedUsers;
  static DateTime? _cachedUsersAt;
  static const Duration _usersCacheTtl = Duration(minutes: 5);

  /// Descarta o cache do quadro de pessoal. Chamado apos criar, editar ou
  /// remover usuario, para a proxima leitura vir do servidor.
  static void invalidateUsersCache() {
    _cachedUsers = null;
    _cachedUsersAt = null;
  }

  Future<List<dynamic>> getUsers({bool forceRefresh = false}) async {
    final cached = _cachedUsers;
    final cachedAt = _cachedUsersAt;
    if (!forceRefresh &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _usersCacheTtl) {
      return cached;
    }
    QuerySnapshot snapshot = await _db.collection('users').get();
    final users = snapshot.docs
        .map((doc) => {'id': doc.id, ...doc.data() as Map<String, dynamic>})
        .toList();
    _cachedUsers = users;
    _cachedUsersAt = DateTime.now();
    return users;
  }

  /// Admin cadastra uma pessoa: ela entra com o CPF e a senha padrao 123456
  /// (devolvida em temporary_password) e cria a propria no primeiro acesso. Sem
  /// [email], a conta usa um e-mail interno tirado do CPF.
  Future<Map<String, dynamic>> createUserAdmin({
    required String name,
    required String cpf,
    String? email,
    required String role,
    required String jobTitle,
    required double dailyHours,
    bool dailyMode = false,
  }) async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/admin/users'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'name': name,
            'cpf': cpfDigits(cpf),
            'email': (email ?? '').trim(),
            'role': role,
            'job_title': jobTitle,
            'daily_hours': dailyHours,
            'daily_mode': dailyMode,
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
    invalidateUsersCache();
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  Future<Map<String, dynamic>> updateUserAdmin(
    dynamic userId, {
    required String name,
    required String email,
    required String role,
    required String jobTitle,
    required double dailyHours,
    required String cpf,
    bool disabled = false,
    String? newPassword,
    bool resetPassword = false,
    bool workScheduleOverrideEnabled = false,
    Map<String, dynamic>? workScheduleOverride,
    bool dailyMode = false,
  }) async {
    final response = await http
        .put(
          Uri.parse('$backendUrl/admin/users/${userId.toString()}'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'name': name,
            'email': email,
            'role': role,
            'job_title': jobTitle,
            'daily_hours': dailyHours,
            'cpf': cpf,
            'disabled': disabled,
            'new_password': newPassword,
            // O backend gera a senha temporaria e devolve em temporary_password.
            'reset_password': resetPassword,
            'work_schedule_override_enabled': workScheduleOverrideEnabled,
            'work_schedule_override': workScheduleOverride,
            'daily_mode': dailyMode,
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        return _updateUserAdminInFirestore(
          userId.toString(),
          name: name,
          email: email,
          role: role,
          jobTitle: jobTitle,
          dailyHours: dailyHours,
          cpf: cpf,
          disabled: disabled,
          // Trocar senha so pelo backend: o plano B recusa como a senha
          // digitada.
          newPassword: resetPassword ? 'senha padrao' : newPassword,
          workScheduleOverrideEnabled: workScheduleOverrideEnabled,
          workScheduleOverride: workScheduleOverride,
          dailyMode: dailyMode,
        );
      }
      throw Exception(_apiError(response));
    }
    invalidateUsersCache();
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  Future<List<Map<String, dynamic>>> getUserNotifications() async {
    final response = await http
        .get(
          Uri.parse('$backendUrl/notifications'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        final user = _auth.currentUser;
        if (user == null) return [];
        // So as nao lidas: e o unico que o sininho exibe, e a colecao so cresce.
        final snapshot = await _db
            .collection('user_notifications')
            .where('user_id', isEqualTo: user.uid)
            .where('is_read', isEqualTo: false)
            .get();
        final notifications = snapshot.docs
            .map((doc) => {'id': doc.id, ...doc.data()})
            .toList()
          ..sort((a, b) =>
              _firestoreCreatedAt(b).compareTo(_firestoreCreatedAt(a)));
        return notifications;
      }
      throw Exception(_apiError(response));
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as List;
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<void> markUserNotificationsRead() async {
    final response = await http
        .post(
          Uri.parse('$backendUrl/notifications/read'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        final user = _auth.currentUser;
        if (user == null) return;
        // Le so o que precisa mudar, em vez da caixa inteira do usuario.
        final snapshot = await _db
            .collection('user_notifications')
            .where('user_id', isEqualTo: user.uid)
            .where('is_read', isEqualTo: false)
            .get();
        if (snapshot.docs.isEmpty) return;
        final batch = _db.batch();
        for (final doc in snapshot.docs) {
          batch.update(doc.reference, {
            'is_read': true,
            'read_at': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        return;
      }
      throw Exception(_apiError(response));
    }
  }

  /// [shiftDay]: dia em que o turno aberto comecou. O pedido de hora extra e
  /// guardado por esse dia; num turno que virou a meia-noite, procurar por
  /// "hoje" nao acharia a liberacao ja dada.
  ///
  /// Sem internet, devolve o ultimo lido neste aparelho (com from_cache):
  /// o estado so na memoria sumia ao reabrir o app offline, e o estagiario
  /// com a hora extra ja liberada ficava preso em "HORARIO PROGRAMADO
  /// ENCERRADO", sem conseguir bater nem guardar a saida.
  Future<Map<String, dynamic>> getEffectiveWorkSchedule(
      {DateTime? shiftDay}) async {
    final shiftDayKey =
        shiftDay == null ? '' : DateFormat('yyyy-MM-dd').format(shiftDay);
    try {
      final uri = Uri.parse('$backendUrl/work-schedule/effective').replace(
          queryParameters:
              shiftDay == null ? null : {'shift_day': shiftDayKey});
      final response = await http
          .get(uri, headers: await _authorizedHeaders())
          .timeout(const Duration(seconds: 20));
      final Map<String, dynamic> state;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode != 404 && response.statusCode < 500) {
          throw Exception(_apiError(response));
        }
        state = await _getEffectiveWorkScheduleFromFirestore(shiftDay: shiftDay);
      } else {
        state = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(response.bodyBytes)) as Map);
      }
      await _cacheWorkSchedule(shiftDayKey, state);
      return state;
    } catch (e) {
      if (!isNetworkFailure(e)) rethrow;
      final cached = await getCachedEffectiveWorkSchedule(shiftDay: shiftDay);
      if (cached == null) rethrow;
      return cached;
    }
  }

  static const String _workScheduleCachePrefix = 'cached_work_schedule_';

  Future<void> _cacheWorkSchedule(
      String shiftDayKey, Map<String, dynamic> state) async {
    try {
      final uid = await _localUserId();
      if (uid == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          '$_workScheduleCachePrefix$uid',
          jsonEncode({
            'shift_day': shiftDayKey,
            'saved_day': DateFormat('yyyy-MM-dd').format(DateTime.now()),
            'state': _jsonSafeValue(state),
          }));
    } catch (e) {
      debugPrint('Nao deu para guardar o horario no aparelho: $e');
    }
  }

  /// Ultimo horario efetivo lido neste aparelho, ou null. O pedido de hora
  /// extra so vale para o mesmo turno ([shiftDay], o dia em que ele
  /// comecou) e o de entrada so no mesmo dia; os outros saem como null.
  Future<Map<String, dynamic>?> getCachedEffectiveWorkSchedule(
      {DateTime? shiftDay}) async {
    try {
      final uid = await _localUserId();
      if (uid == null) return null;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_workScheduleCachePrefix$uid');
      if (raw == null) return null;
      final saved = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final state = Map<String, dynamic>.from(saved['state'] as Map);
      final shiftDayKey =
          shiftDay == null ? '' : DateFormat('yyyy-MM-dd').format(shiftDay);
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      return {
        ...state,
        'overtime_request':
            shiftDayKey.isNotEmpty && saved['shift_day'] == shiftDayKey
                ? state['overtime_request']
                : null,
        'start_request':
            saved['saved_day'] == today ? state['start_request'] : null,
        'from_cache': true,
      };
    } catch (e) {
      debugPrint('Horario guardado no aparelho ilegivel: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> createScheduleControlledPunch({
    required String recordType,
    String? timestamp,
    String? location,
    String? notes,
    double? latitude,
    double? longitude,
    bool closeAtScheduledEnd = false,
    String? clientRecordId,
    bool offline = false,
  }) async {
    // clientRecordId vira o id do ponto e torna o reenvio idempotente;
    // offline = batida feita sem internet e enviada agora (vale a hora dela).
    final response = await http
        .post(
          Uri.parse('$backendUrl/work-schedule/punch'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'record_type': recordType,
            'timestamp': timestamp,
            'location': location,
            'notes': notes,
            'latitude': latitude,
            'longitude': longitude,
            'close_at_scheduled_end': closeAtScheduledEnd,
            if (clientRecordId != null) 'client_record_id': clientRecordId,
            'offline': offline,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        // A tela guarda na fila (isNetworkFailure) e a sincronizacao reenvia
        // pelo backend, com as regras de horario.
        throw ServerUnavailableException(_apiError(response));
      }
      // 401 e 403 (sessao ou perfil: so a autenticacao do backend devolve
      // 403 neste endpoint), 408 e 429 podem passar na proxima tentativa; o
      // resto dos 4xx e a regra recusando a batida.
      if (const {401, 403, 408, 429}.contains(response.statusCode)) {
        throw Exception(_apiError(response));
      }
      throw PunchRejectedException(_apiError(response));
    }
    final result = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
    if (result['status'] == 'created') await _cacheSentRecord(result);
    return result;
  }

  /// Poe na copia local dos pontos um ponto que acabou de chegar ao servidor
  /// (batida do estagiario pelo backend, fila offline sincronizada). Sem
  /// isso, se a leitura logo depois falhasse (rede ruim; no web sempre, sem o
  /// cache do Firestore), a tela offline nao mostrava o ponto, que ja tinha
  /// saido da fila: "Aguardando entrada" com a entrada batida.
  Future<void> _cacheSentRecord(Map<String, dynamic> record) async {
    final uid = _auth.currentUser?.uid;
    final id = record['id']?.toString() ?? '';
    if (uid == null || id.isEmpty || record['user_id']?.toString() != uid) {
      return;
    }
    final copy = Map<String, dynamic>.from(record)
      ..remove('status')
      ..remove('duplicate')
      ..remove('offline')
      ..remove('sync_status')
      ..remove('sync_error')
      ..remove('created_at_local')
      // FieldValue.serverTimestamp() (ou o marcador que o backend devolve).
      ..remove('created_at');
    await _appendCachedTimeRecord(uid, copy);
  }

  Future<Map<String, dynamic>> createScheduleApprovalRequest({
    required String requestType,
    required String attemptedAt,
    String? shiftStartAt,
    String? location,
    String? notes,
    double? latitude,
    double? longitude,
  }) async {
    final observation = notes?.trim() ?? '';
    if (observation.isEmpty) {
      throw Exception('Informe uma observacao explicando a solicitacao.');
    }
    if (observation.length > 500) {
      throw Exception('A observacao deve ter no maximo 500 caracteres.');
    }
    final response = await http
        .post(
          Uri.parse('$backendUrl/work-schedule/approval-requests'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'request_type': requestType,
            'attempted_at': attemptedAt,
            'shift_start_at': shiftStartAt,
            'location': location,
            'notes': observation,
            'latitude': latitude,
            'longitude': longitude,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        return _createScheduleApprovalRequestInFirestore(
          requestType: requestType,
          attemptedAt: attemptedAt,
          shiftStartAt: shiftStartAt,
          location: location,
          notes: observation,
          latitude: latitude,
          longitude: longitude,
        );
      }
      throw Exception(_apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  Future<List<Map<String, dynamic>>> getScheduleApprovalRequests(
      {String? status}) async {
    final uri = Uri.parse('$backendUrl/admin/work-schedule/approval-requests')
        .replace(queryParameters: status == null ? null : {'status': status});
    final response = await http
        .get(uri, headers: await _authorizedHeaders())
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        return _getScheduleApprovalRequestsFromFirestore(status: status);
      }
      throw Exception(_apiError(response));
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as List;
    return decoded
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<void> decideScheduleApproval(
    String requestId, {
    required bool approve,
    String? reason,
  }) async {
    final action = approve ? 'approve' : 'reject';
    final response = await http
        .post(
          Uri.parse(
              '$backendUrl/admin/work-schedule/approval-requests/$requestId/$action'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'reason': reason}),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        await _decideScheduleApprovalInFirestore(
          requestId,
          approve: approve,
          reason: reason,
        );
        return;
      }
      throw Exception(_apiError(response));
    }
  }

  Future<Map<String, dynamic>> getGlobalWorkSchedule() async {
    final response = await http
        .get(
          Uri.parse('$backendUrl/admin/work-schedule/settings'),
          headers: await _authorizedHeaders(),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        return _getGlobalWorkScheduleFromFirestore();
      }
      throw Exception(_apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  Future<Map<String, dynamic>> updateGlobalWorkSchedule(
      Map<String, dynamic> schedule) async {
    final response = await http
        .put(
          Uri.parse('$backendUrl/admin/work-schedule/settings'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(schedule),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404 || response.statusCode >= 500) {
        _logPlanB(response);
        await _db
            .collection('work_schedule_settings')
            .doc('intern_default')
            .set({
          ...schedule,
          'updated_at': FieldValue.serverTimestamp(),
          'updated_by_id': _auth.currentUser?.uid,
        });
        return schedule;
      }
      throw Exception(_apiError(response));
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map);
  }

  static const Map<String, dynamic> _defaultInternSchedule = {
    'shift_start': '13:30',
    'shift_end': '19:30',
    'start_allowed_from': '13:25',
    'start_allowed_until': '19:25',
    'overtime_prompt_after': '19:35',
    'timezone': 'America/Sao_Paulo',
  };

  DateTime _firestoreCreatedAt(Map<String, dynamic> item) {
    final value = item['created_at'];
    if (value is Timestamp) return value.toDate();
    return DateTime.tryParse(value?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<Map<String, dynamic>> _getGlobalWorkScheduleFromFirestore() async {
    try {
      final snapshot = await _db
          .collection('work_schedule_settings')
          .doc('intern_default')
          .get();
      if (snapshot.exists && snapshot.data() != null) {
        return {..._defaultInternSchedule, ...snapshot.data()!};
      }
    } catch (e) {
      debugPrint('Horario global remoto indisponivel, usando padrao: $e');
    }
    return Map<String, dynamic>.from(_defaultInternSchedule);
  }

  Future<Map<String, dynamic>> _getEffectiveWorkScheduleFromFirestore(
      {DateTime? shiftDay}) async {
    final user = await getCurrentUser();
    final override = user['work_schedule_override'];
    final overrideEnabled =
        user['work_schedule_override_enabled'] == true && override is Map;
    final schedule = overrideEnabled
        ? {..._defaultInternSchedule, ...Map<String, dynamic>.from(override)}
        : await _getGlobalWorkScheduleFromFirestore();

    final now = DateTime.now();
    final dayKey = DateFormat('yyyy-MM-dd').format(now);
    // Mesma regra do backend: hora extra pelo dia em que o turno aberto
    // comecou (ate 14 dias atras); a entrada fora do horario, pelo de hoje.
    final today = DateTime(now.year, now.month, now.day);
    final shiftDate = shiftDay == null
        ? null
        : DateTime(shiftDay.year, shiftDay.month, shiftDay.day);
    final overtimeDayKey = shiftDate != null &&
            !shiftDate.isAfter(today) &&
            !shiftDate.isBefore(today.subtract(const Duration(days: 14)))
        ? DateFormat('yyyy-MM-dd').format(shiftDate)
        : dayKey;
    Map<String, dynamic>? overtimeRequest;
    Map<String, dynamic>? startRequest;
    try {
      final snapshot = await _db
          .collection('work_schedule_approval_requests')
          .where('user_id', isEqualTo: user['id'])
          .get();
      final requests = snapshot.docs
          .map((doc) => {'id': doc.id, ...doc.data()})
          .toList()
        ..sort(
            (a, b) => _firestoreCreatedAt(b).compareTo(_firestoreCreatedAt(a)));
      for (final item in requests) {
        if (item['request_type'] == 'overtime' &&
            item['day_key'] == overtimeDayKey &&
            overtimeRequest == null) {
          overtimeRequest = item;
        }
        if (item['request_type'] == 'start_exception' &&
            item['day_key'] == dayKey &&
            startRequest == null) {
          startRequest = item;
        }
      }
    } catch (e) {
      debugPrint('Solicitacoes de horario indisponiveis no Firestore: $e');
    }
    return {
      'schedule': schedule,
      'source': overrideEnabled ? 'user_override' : 'global',
      'server_now': now.toIso8601String(),
      'overtime_request': overtimeRequest,
      'start_request': startRequest,
      'compatibility_mode': true,
    };
  }

  /// Turno aberto do usuario pelo que esta no servidor (14 dias, como o
  /// backend), sem a fila offline deste aparelho.
  Future<Map<String, dynamic>?> _serverOpenShift(String userId) async {
    final scanFrom =
        DateTime.now().subtract(const Duration(days: 14)).toIso8601String();
    final records = (await getTimeRecords(userId: userId, startDate: scanFrom))
        .map((item) => Map<String, dynamic>.from(item as Map))
        .where((record) => record['offline'] != true);
    return openShiftCheckIn(records);
  }

  Future<Map<String, dynamic>> _createScheduleApprovalRequestInFirestore({
    required String requestType,
    required String attemptedAt,
    String? shiftStartAt,
    String? location,
    String? notes,
    double? latitude,
    double? longitude,
  }) async {
    final observation = notes?.trim() ?? '';
    if (observation.isEmpty) {
      throw Exception('Informe uma observacao explicando a solicitacao.');
    }
    if (observation.length > 500) {
      throw Exception('A observacao deve ter no maximo 500 caracteres.');
    }
    final user = await getCurrentUser();
    final state = await _getEffectiveWorkScheduleFromFirestore();
    final attempted = DateTime.parse(attemptedAt);
    final openShift = await _serverOpenShift(user['id'].toString());
    // Hora extra fica no dia em que o turno aberto comecou (o mesmo que a
    // saida consulta), como no backend; num turno que virou a meia-noite o
    // dia da tentativa ja e outro.
    final shiftStart = requestType == 'overtime' && openShift != null
        ? openShift['timestamp']?.toString()
        : shiftStartAt;
    final shiftStarted =
        requestType == 'overtime' ? DateTime.tryParse(shiftStart ?? '') : null;
    final dayKey = DateFormat('yyyy-MM-dd').format(shiftStarted ?? attempted);
    final snapshot = await _db
        .collection('work_schedule_approval_requests')
        .where('user_id', isEqualTo: user['id'])
        .get();
    final candidates = snapshot.docs
        .map((doc) => {'id': doc.id, ...doc.data()})
        .where((data) =>
            data['request_type'] == requestType && data['day_key'] == dayKey)
        .toList()
      ..sort(
          (a, b) => _firestoreCreatedAt(b).compareTo(_firestoreCreatedAt(a)));
    // Mesma regra do backend. Pendente do mesmo dia: o novo pedido e
    // repeticao (retry, toque duplo) e criaria um irmao eternamente pendente;
    // na entrada, so se for da mesma tentativa (_isStartRequestRetry). O
    // antigo fica pendente (as regras nao deixam o estagiario muda-lo), mas a
    // liberacao recusa o pedido que tem um mais novo no dia.
    // Aprovado so conta enquanto vale para o turno atual: a entrada liberada
    // se ela e o turno aberto, a hora extra enquanto o turno segue aberto.
    // Qualquer aprovado do dia valendo dizia "ja liberada" para uma segunda
    // entrada depois de o primeiro turno fechar, sem ponto nenhum.
    Map<String, dynamic>? existing;
    for (final data in candidates) {
      if (data['status'] == 'pending' &&
          (requestType != 'start_exception' ||
              _isStartRequestRetry(
                  DateTime.tryParse(data['attempted_at']?.toString() ?? ''),
                  attempted))) {
        existing = data;
        break;
      }
    }
    if (existing == null && openShift != null) {
      for (final data in candidates) {
        if (data['status'] != 'approved') continue;
        if (requestType != 'start_exception' ||
            data['linked_time_record_id'] == openShift['id']) {
          existing = data;
          break;
        }
      }
    }
    if (existing != null) return {'status': 'existing', 'request': existing};
    // Como no backend: a hora do primeiro pedido pendente que este substitui,
    // para o gestor ver as duas.
    String? previousAttempt;
    if (requestType == 'start_exception') {
      for (final data in candidates) {
        if (data['status'] != 'pending') continue;
        final value = (data['previous_attempted_at'] ?? data['attempted_at'])
                ?.toString() ??
            '';
        if (value.isEmpty) continue;
        if (previousAttempt == null || value.compareTo(previousAttempt) < 0) {
          previousAttempt = value;
        }
      }
    }
    final data = {
      'user_id': user['id'],
      'user_name': user['name'] ?? user['email'] ?? user['id'],
      'user_email': user['email'] ?? '',
      'request_type': requestType,
      'status': 'pending',
      'attempted_at': attempted.toIso8601String(),
      'shift_start_at': shiftStart,
      'day_key': dayKey,
      'location': location ?? 'App',
      'notes': observation,
      'latitude': latitude,
      'longitude': longitude,
      'schedule_snapshot': state['schedule'],
      'compatibility_mode': true,
      if (previousAttempt != null) 'previous_attempted_at': previousAttempt,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    };
    final ref =
        await _db.collection('work_schedule_approval_requests').add(data);
    return {
      'status': 'created',
      'request': {'id': ref.id, ...data}
    };
  }

  Future<List<Map<String, dynamic>>> _getScheduleApprovalRequestsFromFirestore(
      {String? status}) async {
    // Filtra no Firestore, nao em memoria: esta consulta roda em loop na tela
    // de liberacoes e no sininho.
    Query<Map<String, dynamic>> query =
        _db.collection('work_schedule_approval_requests');
    if (status != null) {
      query = query.where('status', isEqualTo: status);
    }
    final snapshot = await query.get();
    final requests = snapshot.docs
        .map((doc) => {'id': doc.id, ...doc.data()})
        .toList()
      ..sort(
          (a, b) => _firestoreCreatedAt(b).compareTo(_firestoreCreatedAt(a)));
    return requests;
  }

  /// Idade maxima do pedido de entrada para a liberacao ainda criar o ponto
  /// (mesma do backend, _START_APPROVAL_MAX_AGE). Mede a idade, nao a data: o
  /// pedido das 23:55 liberado as 00:03 ainda e o mesmo turno.
  static const Duration _startApprovalMaxAge = Duration(hours: 12);

  /// Dois pedidos de entrada ate 15 min um do outro sao a mesma tentativa
  /// repetida (mesma regra do backend, _is_start_request_retry). O pedido
  /// das 08:00 sem resposta engolia o das 15:00, e liberado as 15:05 abria
  /// o turno as 08:00.
  static const Duration _startRequestRetryWindow = Duration(minutes: 15);

  bool _isStartRequestRetry(DateTime? previous, DateTime attempted) =>
      previous == null ||
      previous.difference(attempted).abs() <= _startRequestRetryWindow;

  /// Ha outro pedido de entrada do mesmo dia feito bem depois deste? Liberar
  /// este abriria o turno na hora antiga, que o estagiario ja tinha refeito.
  Future<bool> _hasNewerStartAttempt(
      String requestId, Map<String, dynamic> request) async {
    final attempted =
        DateTime.tryParse(request['attempted_at']?.toString() ?? '');
    if (attempted == null) return false;
    final snapshot = await _db
        .collection('work_schedule_approval_requests')
        .where('user_id', isEqualTo: request['user_id'])
        .get();
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (doc.id == requestId ||
          data['request_type'] != 'start_exception' ||
          data['day_key'] != request['day_key'] ||
          !const {'pending', 'approved', 'rejected'}.contains(data['status'])) {
        continue;
      }
      final other = DateTime.tryParse(data['attempted_at']?.toString() ?? '');
      if (other != null &&
          other.isAfter(attempted) &&
          !_isStartRequestRetry(attempted, other)) {
        return true;
      }
    }
    return false;
  }

  /// check_in ja gravado que atende este pedido de entrada (mesma regra do
  /// backend, _reusable_approval_check_in). Primeiro o do proprio pedido;
  /// depois o de OUTRO pedido do mesmo dia, so se for o mesmo turno: ainda
  /// aberto, ou este pedido foi feito antes da saida dele. Pedido feito
  /// depois daquela saida e uma nova entrada e precisa do proprio ponto;
  /// reaproveitar so ligava o pedido a um turno ja fechado.
  Map<String, dynamic>? _reusableApprovalCheckIn(
    List<Map<String, dynamic>> records,
    String requestId,
    Map<String, dynamic> request,
    Map<String, dynamic>? openShift,
  ) {
    for (final record in records) {
      if (record['record_type'] == 'check_in' &&
          record['schedule_approval_request_id'] == requestId) {
        return record;
      }
    }
    final attempted =
        DateTime.tryParse(request['attempted_at']?.toString() ?? '');
    // Sem day_key, um valor que nenhum timestamp tem.
    final dayKey = request['day_key']?.toString() ?? ' ';
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final linked = record['schedule_approval_request_id']?.toString() ?? '';
      if (record['record_type'] != 'check_in' || linked.isEmpty) continue;
      final timestamp = record['timestamp']?.toString() ?? '';
      if (dayKey.isEmpty || !timestamp.startsWith(dayKey)) continue;
      if (openShift != null && record['id'] == openShift['id']) return record;
      Map<String, dynamic>? following;
      for (final later in records.skip(i + 1)) {
        final type = later['record_type'];
        if (type == 'check_in' || type == 'check_out') {
          following = later;
          break;
        }
      }
      if (following == null || following['record_type'] != 'check_out') {
        continue;
      }
      final ended = DateTime.tryParse(following['timestamp']?.toString() ?? '');
      if (attempted != null && ended != null && !attempted.isAfter(ended)) {
        return record;
      }
    }
    return null;
  }

  Future<void> _decideScheduleApprovalInFirestore(
    String requestId, {
    required bool approve,
    String? reason,
  }) async {
    final manager = await getCurrentUser();
    if (manager['role'] != 'admin' && manager['role'] != 'manager') {
      throw Exception('Apenas gestores podem decidir liberacoes.');
    }
    final requestRef =
        _db.collection('work_schedule_approval_requests').doc(requestId);
    final snapshot = await requestRef.get();
    if (!snapshot.exists || snapshot.data() == null) {
      throw Exception('Solicitacao nao encontrada.');
    }
    final request = snapshot.data()!;
    final currentStatus = request['status']?.toString();
    // Decisao ja aplicada (ex.: o backend concluiu e so a resposta se perdeu):
    // repetir a mesma decisao e sucesso, nao erro.
    if (currentStatus == (approve ? 'approved' : 'rejected')) return;
    if (currentStatus != 'pending') {
      throw Exception('Esta solicitacao ja foi decidida.');
    }

    final batch = _db.batch();
    String? linkedRecordId;
    if (approve && request['request_type'] == 'start_exception') {
      final scanFrom =
          DateTime.now().subtract(const Duration(days: 14)).toIso8601String();
      final records = sortRecords(
          (await getTimeRecords(userId: request['user_id'], startDate: scanFrom))
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList());
      // Mesma regra do backend: a noite do lote do gestor ja vem fechada.
      final openShift = openShiftCheckIn(records);
      // Procura pelo vinculo, nao pelo turno aberto: o ponto pode ter sido
      // gravado por uma tentativa anterior e o turno ja ter sido encerrado.
      final existing =
          _reusableApprovalCheckIn(records, requestId, request, openShift);
      final attempted =
          DateTime.tryParse(request['attempted_at']?.toString() ?? '');
      if (existing != null) {
        // A tentativa anterior gravou o ponto mas nao concluiu a decisao (por
        // isso o pedido continuou pendente na lista). Reaproveita o ponto que
        // ja existe; criar outro duplicaria a entrada.
        linkedRecordId = existing['id']?.toString();
      } else if (attempted != null &&
          DateTime.now().difference(attempted) > _startApprovalMaxAge) {
        // Liberar agora um pedido de muitas horas atras gravaria a entrada na
        // hora dele, abrindo um turno que ja passou.
        throw Exception('Pedido antigo: a entrada nao foi criada. Rejeite e '
            'lance o ponto pelo lote se for o caso.');
      } else if (await _hasNewerStartAttempt(requestId, request)) {
        throw Exception('O estagiario pediu a entrada de novo mais tarde '
            'neste dia: libere o pedido mais recente.');
      } else if (openShift != null) {
        throw Exception('O usuario ja possui um turno aberto.');
      } else {
        // Id deterministico: reenviar a liberacao regrava o mesmo documento em
        // vez de criar um segundo check_in.
        final recordRef =
            _db.collection('time_records').doc('approval_$requestId');
        linkedRecordId = recordRef.id;
        batch.set(recordRef, {
          'user_id': request['user_id'],
          'record_type': 'check_in',
          'location': request['location'] ?? 'App (aprovado)',
          'notes':
              request['notes'] ?? 'Entrada fora do horario aprovada pelo gestor',
          'timestamp': request['attempted_at'],
          'latitude': request['latitude'],
          'longitude': request['longitude'],
          'schedule_controlled': true,
          'schedule_approval_request_id': requestId,
          'approved_by_id': manager['id'],
          'approved_by_name': manager['name'] ?? manager['email'],
          'schedule_snapshot': request['schedule_snapshot'],
          'compatibility_mode': true,
          'created_at': FieldValue.serverTimestamp(),
        });
      }
    }
    batch.update(requestRef, {
      'status': approve ? 'approved' : 'rejected',
      'decision_reason': reason?.trim() ?? '',
      'decided_by_id': manager['id'],
      'decided_by_name': manager['name'] ?? manager['email'] ?? 'Gestor',
      'decided_at': FieldValue.serverTimestamp(),
      'linked_time_record_id': linkedRecordId,
      'updated_at': FieldValue.serverTimestamp(),
    });
    await batch.commit();

    try {
      await _db.collection('user_notifications').add({
        'user_id': request['user_id'],
        'title': approve ? 'Horario liberado' : 'Horario nao liberado',
        'body': approve
            ? 'Sua solicitacao de horario foi liberada pelo gestor.'
            : 'O gestor nao liberou sua solicitacao de horario.',
        'type': 'schedule_decision',
        'request_id': requestId,
        'is_read': false,
        'created_at': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('Decisao salva, mas notificacao interna falhou: $e');
    }
  }

  Future<void> deleteUserAdmin(dynamic userId) async {
    final targetId = userId.toString();
    final currentUser = _auth.currentUser;

    if (currentUser == null) {
      throw Exception('Usuario nao autenticado.');
    }

    if (currentUser.uid == targetId) {
      throw Exception('Voce nao pode excluir a propria conta.');
    }

    final token = await currentUser.getIdToken();
    final response = await http.delete(
      Uri.parse('$backendUrl/admin/users/$targetId'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    ).timeout(const Duration(seconds: 45));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String detail = response.body;
      try {
        final decoded = jsonDecode(response.body);
        detail = decoded['detail']?.toString() ?? response.body;
      } catch (_) {}
      throw Exception('Falha ao excluir usuario: $detail');
    }
    invalidateUsersCache();
  }

  Future<List<dynamic>> getAdminTimeRecords({
    dynamic userId,
    String? startDate,
    String? endDate,
  }) async {
    // O filtro de data vai para o Firestore. Antes ele era aplicado em memoria
    // DEPOIS de baixar a colecao inteira: a aba Resumo, atualizando sozinha,
    // relia todo o historico de pontos da empresa a cada ciclo e sozinha
    // esgotava a cota diaria de leituras (o custo crescia com o acumulado, nao
    // com o uso). Exige o indice user_id + timestamp; intervalo so por data usa
    // o indice automatico.
    Query<Map<String, dynamic>> base = _db.collection('time_records');
    if (userId != null && userId.toString().isNotEmpty) {
      base = base.where('user_id', isEqualTo: userId.toString());
    }
    Query<Map<String, dynamic>> query = base;
    if (startDate != null) {
      query = query.where('timestamp', isGreaterThanOrEqualTo: startDate);
    }
    if (endDate != null) {
      query = query.where('timestamp', isLessThanOrEqualTo: endDate);
    }

    List<Map<String, dynamic>> records;
    try {
      final snapshot = await query.get();
      records =
          snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (e) {
      // Sem o indice composto: nao quebra a tela, mas volta a custar caro.
      debugPrint('Consulta por data indisponivel, usando fallback: $e');
      final snapshot = await base.get();
      records =
          snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    }

    // Do mais novo para o mais antigo; no mesmo horario, a ordem vem do
    // tipo (sortRecords), como no calculo do turno.
    records = sortRecords(records).reversed.toList();
    // Mantido: o fallback acima e os registros gravados sem hora exata ainda
    // precisam do recorte em memoria.
    if (startDate != null || endDate != null) {
      records = records.where((r) {
        final ts = r['timestamp'] as String;
        bool match = true;
        if (startDate != null) match = match && ts.compareTo(startDate) >= 0;
        if (endDate != null) match = match && ts.compareTo(endDate) <= 0;
        return match;
      }).toList();
    }
    return records;
  }

  /// Admin apaga uma batida errada (botao apertado sem querer, toque duplo),
  /// pelo backend: a copia do registro fica na auditoria com o motivo.
  Future<void> deleteTimeRecordAdmin(
      {required String recordId, required String reason}) async {
    final response = await http
        .delete(
          Uri.parse(
              '$backendUrl/admin/time-records/${Uri.encodeComponent(recordId)}'),
          headers: {
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'reason': reason}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response));
    }
  }

  Future<void> updateTimeRecordAdmin({
    required String recordId,
    required String newTimestamp,
    required String reason,
    String? notes,
    // Botao errado (ex.: "pausa" no lugar de "saida"): troca o tipo.
    String? newRecordType,
  }) async {
    final admin = await getCurrentUser();
    if (admin['role'] != 'admin') {
      throw Exception('Apenas admin pode editar registros de ponto.');
    }
    final recordRef = _db.collection('time_records').doc(recordId);
    final auditRef = _db.collection('time_record_audits').doc();

    await _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(recordRef);
      if (!snapshot.exists) {
        throw Exception('Registro de ponto nao encontrado.');
      }

      final oldData = snapshot.data() as Map<String, dynamic>;
      final oldTimestamp = oldData['timestamp']?.toString();
      final oldNotes = oldData['notes']?.toString();
      final oldType = oldData['record_type']?.toString();
      final recordType =
          (newRecordType != null && newRecordType.isNotEmpty) ? newRecordType : oldType;

      transaction.update(recordRef, {
        'timestamp': newTimestamp,
        'record_type': recordType,
        'notes': notes ?? '',
        'updated_at': FieldValue.serverTimestamp(),
        'edited_by_admin': true,
        'admin_edit_message': 'Editado pelo admin',
        'last_admin_edit_reason': reason,
        'last_admin_edit_by_id': admin['id'],
        'last_admin_edit_by_name': admin['name'] ?? admin['email'] ?? 'Admin',
        'last_admin_edit_at': FieldValue.serverTimestamp(),
      });

      transaction.set(auditRef, {
        'action': 'edit',
        'record_id': recordId,
        'record_user_id': oldData['user_id'],
        'record_type': oldType,
        'old_record_type': oldType,
        'new_record_type': recordType,
        'old_timestamp': oldTimestamp,
        'new_timestamp': newTimestamp,
        'old_notes': oldNotes,
        'new_notes': notes ?? '',
        'reason': reason,
        'admin_id': admin['id'],
        'admin_name': admin['name'] ?? '',
        'admin_email': admin['email'] ?? '',
        'edited_at': FieldValue.serverTimestamp(),
        'created_at': FieldValue.serverTimestamp(),
      });
    });
  }
}
