import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Push recebido com o app aberto no navegador. O FCM so mostra sozinho com o
/// app fechado ou em segundo plano (firebase-messaging-sw.js), e o
/// flutter_local_notifications nao funciona no web: sem isto o aviso chegava e
/// ninguem via.
Future<void> showWebNotification(String title, String body) async {
  try {
    if (web.Notification.permission != 'granted') return;
    // Pelo service worker: no Android o construtor Notification() nao existe
    // dentro da pagina.
    final registration = await web.window.navigator.serviceWorker.ready.toDart;
    await registration
        .showNotification(title, web.NotificationOptions(body: body, icon: '/icons/Icon-192.png'))
        .toDart;
  } catch (_) {
    // Sem service worker ou sem permissao: o sino do app mostra o aviso.
  }
}
