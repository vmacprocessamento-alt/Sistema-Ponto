import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'services/api_service.dart';
import 'services/session_service.dart';
import 'services/theme_service.dart';
import 'services/update_service.dart';
import 'widgets/startup_loading.dart';
import 'widgets/update_banner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Atualizacao automatica: recarrega na versao nova quando ninguem esta
    // usando a tela. A fila offline subindo nao pode ser cortada no meio.
    UpdateService.instance
      ..addBusyCheck(() => ApiService.offlineSyncRunning)
      ..start();
  }
  runApp(const AppBootstrap());
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  late Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    _initialization = _initialize();
  }

  Future<void> _initialize() async {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 20));
    _configureFirestoreCache();
    if (DefaultFirebaseOptions.useEmulator) {
      // Depois do _configureFirestoreCache: trocar settings depois apagaria o
      // endereco do emulador.
      await FirebaseAuth.instance.useAuthEmulator('127.0.0.1', 9099);
      FirebaseFirestore.instance.useFirestoreEmulator('127.0.0.1', 8085);
    }
    await initializeDateFormatting('pt_BR', null);
  }

  /// Cache local do Firestore: DESLIGADO (memoria). Com o cache em IndexedDB ligado, o
  /// Safari do iPhone travava o Firestore depois de fechar e reabrir o app
  /// (o IndexedDB do WebKit fica preso), e a tela de ponto girava sem fim,
  /// com ou sem internet. O que o app precisa ver offline (perfil, pontos dos
  /// ultimos dias e a fila de pontos) fica na copia propria do ApiService, em
  /// SharedPreferences.
  void _configureFirestoreCache() {
    try {
      FirebaseFirestore.instance.settings =
          const Settings(persistenceEnabled: false);
    } catch (e) {
      debugPrint('Nao deu para configurar o cache do Firestore: $e');
    }
  }

  void _retry() {
    setState(() {
      _initialization = _initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initialization,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Nao foi possivel iniciar o aplicativo.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        snapshot.error.toString(),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _retry,
                        child: const Text('Tentar novamente'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        if (snapshot.connectionState != ConnectionState.done) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: StartupLoading(from: 80, to: 88)),
          );
        }

        return ChangeNotifierProvider(
          create: (_) => ThemeService(),
          child: const MyApp(),
        );
      },
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);

    return MaterialApp(
      title: 'Vmac Ponto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        // Fonte embutida no app (assets/fonts): sem ela o Flutter web baixa a
        // Roboto do fonts.gstatic.com e, offline, o texto some da tela.
        fontFamily: 'Roboto',
        primaryColor: const Color(0xFF8B0000),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B0000),
          primary: const Color(0xFF8B0000),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 2,
        ),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
        primaryColor: const Color(0xFF8B0000),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B0000),
          primary: const Color(0xFF8B0000),
          brightness: Brightness.dark,
          surface: const Color(0xFF1E1E1E),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        cardTheme: const CardThemeData(
          color: Color(0xFF1E1E1E),
          elevation: 0,
        ),
      ),
      themeMode: themeService.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      // Atualizacao automatica: sabe quando ha dialogo ou tela por cima e
      // mostra a barra "Nova versao do app" quando nao da para recarregar.
      navigatorObservers: [UpdateService.instance.navigatorObserver],
      builder: (context, child) =>
          UpdateBanner(child: child ?? const SizedBox.shrink()),
      home: const AuthGate(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('pt', 'BR'),
      ],
      locale: const Locale('pt', 'BR'),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<User?> _restoredSession;

  @override
  void initState() {
    super.initState();
    _restoredSession = SessionService.restoreSession();
  }

  static const Widget _splash =
      Scaffold(body: StartupLoading(from: 88, to: 94));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<User?>(
      future: _restoredSession,
      builder: (context, restoreSnapshot) {
        // Enquanto a sessao guardada nao for resolvida nao mostramos o login:
        // um null passageiro aqui faria o usuario logado digitar senha a toa.
        if (restoreSnapshot.connectionState != ConnectionState.done) {
          return _splash;
        }

        return StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          initialData: restoreSnapshot.data ?? FirebaseAuth.instance.currentUser,
          builder: (context, authSnapshot) {
            if (authSnapshot.data != null) {
              return const MainScreen();
            }

            if (authSnapshot.connectionState == ConnectionState.waiting) {
              return _splash;
            }

            return const LoginScreen();
          },
        );
      },
    );
  }
}
