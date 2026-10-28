import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'services/app_permission_service.dart';
import 'services/notification_service.dart';
import 'services/session_service.dart';
import 'services/theme_service.dart';
import 'widgets/startup_loading.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

    if (!kIsWeb) {
      unawaited(NotificationService.initialize());
    }
  }

  /// Cache local do Firestore.
  ///
  /// No web ele fica DESLIGADO (memoria). Com o cache em IndexedDB ligado, o
  /// Safari do iPhone travava o Firestore depois de fechar e reabrir o app
  /// (o IndexedDB do WebKit fica preso), e a tela de ponto girava sem fim,
  /// com ou sem internet. O que o app precisa ver offline (perfil, pontos dos
  /// ultimos dias e a fila de pontos) fica na copia propria do ApiService, em
  /// SharedPreferences. No Android/iOS nativo o padrao do SDK e mantido.
  void _configureFirestoreCache() {
    if (!kIsWeb) return;
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
      home: const PermissionGate(child: AuthGate()),
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

class PermissionGate extends StatefulWidget {
  final Widget child;

  const PermissionGate({super.key, required this.child});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate>
    with WidgetsBindingObserver {
  bool _isChecking = true;
  bool _hasPermissions = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestAndCheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkOnly();
    }
  }

  Future<void> _requestAndCheck() async {
    setState(() => _isChecking = true);
    final ok = await AppPermissionService.requestCorePermissions();
    if (!mounted) return;
    setState(() {
      _hasPermissions = ok;
      _isChecking = false;
    });
  }

  Future<void> _checkOnly() async {
    final ok = await AppPermissionService.hasCorePermissions();
    if (!mounted) return;
    setState(() => _hasPermissions = ok);
  }

  Future<void> _openSettings() async {
    await AppPermissionService.openSettings();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasPermissions) return widget.child;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(
                    'assets/images/vmac_logo.jpg',
                    height: 120,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'Libere as configurações',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E1E1E),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Para acessar o Ponto_VMac, libere notificações, localização e microfone.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _isChecking ? null : _requestAndCheck,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B0000),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(
                        _isChecking ? 'Verificando...' : 'Liberar permissões'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _openSettings,
                    child: const Text('Abrir configurações do app'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
