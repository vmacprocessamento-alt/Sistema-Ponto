/* Service worker do Firebase Cloud Messaging (push no app web).
 *
 * O FCM do navegador procura este arquivo na raiz do site. Sem ele o
 * getToken() falhava (404), o token nunca era salvo e quem usa o ponto pelo
 * navegador nao recebia nenhum push: liberacao de horario, pausa fechada,
 * documento para assinar (28/10/2026).
 *
 * Fica num escopo proprio (/firebase-cloud-messaging-push-scope) e nao mexe
 * no cache do app, que e do pwa_service_worker.js.
 *
 * A versao do SDK acompanha a do firebase_core_web (supportedFirebaseJsSdkVersion
 * em firebase_sdk_version.dart): trocar junto quando o pacote subir.
 */
importScripts('https://www.gstatic.com/firebasejs/11.9.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/11.9.1/firebase-messaging-compat.js');

// Toque na notificacao: abre (ou traz para frente) o app. Registrado antes do
// firebase.messaging() para valer tambem nas notificacoes que o FCM mostra.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
      const app = windows.find((client) => new URL(client.url).origin === self.location.origin);
      if (app) return app.focus();
      return self.clients.openWindow('/');
    }),
  );
});

// Mesma configuracao web de lib/firebase_options.dart (publica: vai junto no
// main.dart.js de qualquer forma).
firebase.initializeApp({
  apiKey: 'AIzaSyDtE1kvZ2tnXJxMFT6gugigjkn-GrKS15o',
  authDomain: 'ponto-vmac.firebaseapp.com',
  projectId: 'ponto-vmac',
  storageBucket: 'ponto-vmac.firebasestorage.app',
  messagingSenderId: '702496632234',
  appId: '1:702496632234:web:62af882302344f38734fd3',
});

// Com o app fechado ou em segundo plano, o FCM mostra sozinho as mensagens com
// "notification" (as que o backend manda).
firebase.messaging();
