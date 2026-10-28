import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show debugPrint, debugPrintStack;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../firebase_options.dart';

class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static const int _internReminderId = 1002;
  static bool _pushListenersConfigured = false;
  // Resultado da inicializacao do plugin (true = pronto). Fica null quando o
  // initialize() nao rodou, como no web (main.dart). Sem o plugin pronto,
  // show/zonedSchedule/cancel lancam excecao; no web isso fazia a tela de
  // ponto regravar o retorno da pausa automatica a cada segundo.
  static Future<bool>? _pluginReady;

  static const AndroidNotificationChannel _breakChannel =
      AndroidNotificationChannel(
    'break_auto_close',
    'Fechamento de pausas',
    description: 'Avisos quando uma pausa e fechada automaticamente.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static const AndroidNotificationChannel _internReminderChannel =
      AndroidNotificationChannel(
    'intern_open_point_reminder',
    'Lembretes de ponto aberto',
    description: 'Avisos para estagiarios com ponto aberto no horario limite.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static const AndroidNotificationChannel _signatureDocumentsChannel =
      AndroidNotificationChannel(
    'signature_documents',
    'Documentos para assinatura',
    description: 'Avisos de documentos enviados pelo RH para assinatura.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static const AndroidNotificationChannel _workScheduleApprovalsChannel =
      AndroidNotificationChannel(
    'work_schedule_approvals',
    'Liberações de horário',
    description: 'Solicitações e decisões de liberação de horário.',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static Future<void> initialize() async {
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('America/Sao_Paulo'));

    const androidSettings = AndroidInitializationSettings('notification_icon');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const initializationSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    final pluginInit = _plugin.initialize(settings: initializationSettings);
    _pluginReady = pluginInit.then((_) => true, onError: (Object _) => false);
    await pluginInit;

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_breakChannel);
    await androidPlugin?.createNotificationChannel(_internReminderChannel);
    await androidPlugin?.createNotificationChannel(_signatureDocumentsChannel);
    await androidPlugin
        ?.createNotificationChannel(_workScheduleApprovalsChannel);
    await androidPlugin?.requestNotificationsPermission();
    await _configurePushNotifications();
  }

  /// Espera a inicializacao em andamento (um aviso logo na abertura do app
  /// nao se perde) e diz se o plugin pode ser usado.
  static Future<bool> _isReady() => _pluginReady ?? Future.value(false);

  static Future<void> _show({
    required int id,
    required String title,
    required String body,
    required NotificationDetails details,
  }) async {
    if (!await _isReady()) return;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  static Future<void> _configurePushNotifications() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    Future<void> saveToken(String? token) async {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || token == null || token.isEmpty) return;
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'fcm_tokens': FieldValue.arrayUnion([token]),
        'fcm_token_updated_at': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
    }

    try {
      await saveToken(await messaging.getToken());
      if (_pushListenersConfigured) return;
      _pushListenersConfigured = true;
      messaging.onTokenRefresh.listen(saveToken);
      FirebaseMessaging.onMessage.listen((message) {
        final notification = message.notification;
        if (notification == null) return;
        final isScheduleNotification =
            message.data['type']?.toString().startsWith('schedule_') == true;
        final androidDetails = AndroidNotificationDetails(
          isScheduleNotification
              ? 'work_schedule_approvals'
              : 'signature_documents',
          isScheduleNotification
              ? 'Liberações de horário'
              : 'Documentos para assinatura',
          channelDescription: isScheduleNotification
              ? 'Solicitações e decisões de liberação de horário.'
              : 'Avisos de documentos enviados pelo RH para assinatura.',
          importance: Importance.max,
          priority: Priority.high,
        );
        _show(
          id: 1004,
          title: notification.title ?? 'Nova notificação',
          body: notification.body ?? '',
          details: NotificationDetails(
            android: androidDetails,
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
        );
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

  static Future<void> showBreakAutoClosed({
    required DateTime closedAt,
  }) async {
    final time = DateFormat('HH:mm:ss').format(closedAt);

    const androidDetails = AndroidNotificationDetails(
      'break_auto_close',
      'Fechamento de pausas',
      channelDescription: 'Avisos quando uma pausa e fechada automaticamente.',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      ticker: 'Pausa fechada automaticamente',
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _show(
      id: 1001,
      title: 'Pausa fechada automaticamente',
      body:
          'Provavelmente voce esqueceu a pausa aberta. Fechando a pausa $time e retomando o turno.',
      details: details,
    );
  }

  static Future<void> showInternOpenPointReminder() async {
    const androidDetails = AndroidNotificationDetails(
      'intern_open_point_reminder',
      'Lembretes de ponto aberto',
      channelDescription:
          'Avisos para estagiarios com ponto aberto no horario limite.',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      ticker: 'Talvez voce tenha esquecido o ponto aberto',
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _show(
      id: _internReminderId,
      title: 'Decida como encerrar o expediente',
      body:
          'Abra o app para fechar no horario programado ou pedir liberacao para continuar.',
      details: details,
    );
  }

  static Future<void> scheduleInternOpenPointReminder(
    DateTime reference, {
    DateTime? scheduledAt,
  }) async {
    final effectiveScheduledAt = scheduledAt ??
        DateTime(
          reference.year,
          reference.month,
          reference.day,
          19,
          35,
        );

    if (!await _isReady()) return;
    await cancelInternOpenPointReminder();
    if (!effectiveScheduledAt.isAfter(reference)) return;

    const androidDetails = AndroidNotificationDetails(
      'intern_open_point_reminder',
      'Lembretes de ponto aberto',
      channelDescription:
          'Avisos para estagiarios com ponto aberto no horario limite.',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      ticker: 'Talvez voce tenha esquecido o ponto aberto',
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    await _plugin.zonedSchedule(
      id: _internReminderId,
      title: 'Decida como encerrar o expediente',
      body:
          'Abra o app para fechar no horario programado ou pedir liberacao para continuar.',
      scheduledDate: tz.TZDateTime.from(effectiveScheduledAt, tz.local),
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  static Future<void> cancelInternOpenPointReminder() async {
    if (!await _isReady()) return;
    await _plugin.cancel(id: _internReminderId);
  }

  static Future<void> showSignatureRequest({
    required int pendingCount,
    required String title,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'signature_documents',
      'Documentos para assinatura',
      channelDescription:
          'Avisos de documentos enviados pelo RH para assinatura.',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      ticker: 'Documento aguardando assinatura',
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    await _show(
      id: 1003,
      title: 'Você tem documento para assinar',
      body: pendingCount == 1
          ? 'RH enviou "$title" para sua assinatura.'
          : 'RH enviou $pendingCount documentos para sua assinatura.',
      details: const NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      ),
    );
  }
}
