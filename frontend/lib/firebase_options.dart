import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  /// Build de teste contra o emulador local do Firebase:
  /// flutter build web --dart-define=USE_FIREBASE_EMULATOR=true
  /// Projeto "demo-": o SDK nao consegue falar com nenhum Firebase real.
  static const bool useEmulator = bool.fromEnvironment('USE_FIREBASE_EMULATOR');

  static const FirebaseOptions emulator = FirebaseOptions(
    apiKey: 'demo-key',
    appId: '1:000000000000:web:0000000000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'demo-ponto',
    // Sem bucket o FirebaseStorage.instance do ApiService quebra a abertura.
    storageBucket: 'demo-ponto.appspot.com',
  );

  static FirebaseOptions get currentPlatform {
    if (useEmulator) return emulator;
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDtE1kvZ2tnXJxMFT6gugigjkn-GrKS15o',
    authDomain: 'ponto-vmac.firebaseapp.com',
    projectId: 'ponto-vmac',
    storageBucket: 'ponto-vmac.firebasestorage.app',
    messagingSenderId: '702496632234',
    appId: '1:702496632234:web:62af882302344f38734fd3',
    measurementId: 'G-QND51815P3',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDFzubIuTE53oSOHMlj-tuqrpa2QUlO_pE',
    appId: '1:702496632234:android:7062b815919d31f1734fd3',
    messagingSenderId: '702496632234',
    projectId: 'ponto-vmac',
    storageBucket: 'ponto-vmac.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDtE1kvZ2tnXJxMFT6gugigjkn-GrKS15o',
    appId: '1:702496632234:ios:62af882302344f38734fd3',
    messagingSenderId: '702496632234',
    projectId: 'ponto-vmac',
    storageBucket: 'ponto-vmac.firebasestorage.app',
    iosBundleId: 'com.example.pontoApp',
  );
}
