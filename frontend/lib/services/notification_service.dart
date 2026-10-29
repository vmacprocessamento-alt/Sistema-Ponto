import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show debugPrint, debugPrintStack;
import 'package:intl/intl.dart';

import '../firebase_options.dart';
import 'web_notification.dart';

/// Avisos do app, so no navegador (o app e so web desde 28/10/2026).
///
/// Push (FCM): com o app fechado ou em segundo plano quem mostra e o
/// firebase-messaging-sw.js; com ele aberto, showWebNotification. Os avisos
/// gerados pelo proprio app (pausa fechada, lembrete do estagiario, documento
/// para assinar) tambem saem pela notificacao do navegador.
class NotificationService {
  NotificationService._();

  static bool _pushListenersConfigured = false;

  // Lembrete do estagiario com ponto aberto no limite do horario. O navegador
  // nao agenda aviso para depois: vale enquanto o app estiver aberto.
  static Timer? _internReminder;

  static Future<void> _configurePushNotifications() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    Future<void> saveToken(String? token) async {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || token == null || token.isEmpty) return;
      // update (e nao set com merge): o cache do Firestore e so de memoria e,
      // ao reabrir o app, o perfil ainda nao foi lido. O set com merge criava
      // no aparelho um users/{uid} so com estes dois campos; com o Firestore
      // demorando a conectar (iPhone ao reabrir), a leitura do perfil devolvia
      // essa copia: "Carregando..." no nome e a aba Gestao sumia (29/10/2026).
      // O cadastro sempre existe (sem ele o login nao entra).
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'fcm_tokens': FieldValue.arrayUnion([token]),
        'fcm_token_updated_at': DateTime.now().toIso8601String(),
      });
    }

    try {
      await saveToken(await messaging.getToken());
      if (_pushListenersConfigured) return;
      _pushListenersConfigured = true;
      messaging.onTokenRefresh.listen(saveToken);
      FirebaseMessaging.onMessage.listen((message) {
        final notification = message.notification;
        if (notification == null) return;
        showWebNotification(
            notification.title ?? 'Nova notificação', notification.body ?? '');
      });
    } catch (error, stackTrace) {
      debugPrint('Falha ao configurar notificacoes push: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  static Future<void> registerCurrentDevice() async {
    // Build de teste no emulador: o FCM nao tem emulador e o pedido de token
    // iria ao Google com a configuracao falsa do projeto demo.
    if (DefaultFirebaseOptions.useEmulator) return;
    await _configurePushNotifications();
  }

  static Future<void> showBreakAutoClosed({required DateTime closedAt}) {
    final time = DateFormat('HH:mm:ss').format(closedAt);
    return showWebNotification(
      'Pausa fechada automaticamente',
      'Provavelmente voce esqueceu a pausa aberta. Fechando a pausa $time e '
          'retomando o turno.',
    );
  }

  static Future<void> showInternOpenPointReminder() => showWebNotification(
        'Decida como encerrar o expediente',
        'Abra o app para fechar no horario programado ou pedir liberacao para '
            'continuar.',
      );

  static Future<void> scheduleInternOpenPointReminder(
    DateTime reference, {
    DateTime? scheduledAt,
  }) async {
    final effectiveScheduledAt = scheduledAt ??
        DateTime(reference.year, reference.month, reference.day, 19, 35);
    await cancelInternOpenPointReminder();
    if (!effectiveScheduledAt.isAfter(reference)) return;
    _internReminder = Timer(effectiveScheduledAt.difference(reference),
        () => unawaited(showInternOpenPointReminder()));
  }

  static Future<void> cancelInternOpenPointReminder() async {
    _internReminder?.cancel();
    _internReminder = null;
  }

  static Future<void> showSignatureRequest({
    required int pendingCount,
    required String title,
  }) =>
      showWebNotification(
        'Você tem documento para assinar',
        pendingCount == 1
            ? 'RH enviou "$title" para sua assinatura.'
            : 'RH enviou $pendingCount documentos para sua assinatura.',
      );
}
