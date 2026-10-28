import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;

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

  /// O app e so web (desde 28/10/2026).
  static FirebaseOptions get currentPlatform => useEmulator ? emulator : web;

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDtE1kvZ2tnXJxMFT6gugigjkn-GrKS15o',
    authDomain: 'ponto-vmac.firebaseapp.com',
    projectId: 'ponto-vmac',
    storageBucket: 'ponto-vmac.firebasestorage.app',
    messagingSenderId: '702496632234',
    appId: '1:702496632234:web:62af882302344f38734fd3',
    measurementId: 'G-QND51815P3',
  );
}
