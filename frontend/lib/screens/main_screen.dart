import 'dart:async';

import 'package:flutter/material.dart';
import 'home_screen.dart';
import 'change_password_screen.dart';
import 'daily_mode_screen.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'admin_screen.dart';
import 'profile_screen.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../widgets/content_width.dart';
import '../widgets/startup_loading.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  final _apiService = ApiService();
  bool _isAdmin = false;
  // Modo diaria (users.daily_mode): a aba Ponto vira o botao da diaria.
  bool _dailyMode = false;
  // Perfil ja lido: so entao se sabe qual tela de ponto abrir (e se a senha
  // precisa ser criada). Montar as abas antes lia 14 dias de pontos a toa.
  bool _profileReady = false;
  // Primeiro acesso ou senha redefinida pelo admin: cria a senha antes de
  // qualquer outra tela.
  bool _mustChangePassword = false;
  // Senha ja criada nesta abertura: o perfil do servidor lido antes da troca
  // ainda traz a marca e nao pode reabrir a tela.
  bool _passwordChanged = false;
  String? _cpf;
  // Algum perfil (do aparelho ou do servidor) ja foi aplicado.
  bool _hasProfile = false;
  // Perfil que nao veio (servidor lento ou fora, sem copia no aparelho):
  // tenta de novo sozinho. Antes a aba Gestao do admin sumia ate a pessoa
  // recarregar a pagina, porque o perfil era lido uma vez so.
  Timer? _profileRetryTimer;
  int _profileRetryAttempt = 0;

  @override
  void initState() {
    super.initState();
    NotificationService.registerCurrentDevice();
    _loadUser();
  }

  @override
  void dispose() {
    _profileRetryTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUser() async {
    // Copia local primeiro (na hora, com ou sem internet); depois o perfil
    // do servidor, que traz a mudanca de modo feita pelo admin.
    if (!_hasProfile) {
      try {
        final cached = await _apiService.getCachedCurrentUser();
        if (cached != null) _applyUser(cached);
      } catch (e) {
        debugPrint('Perfil local indisponível: $e');
      }
    }
    try {
      _applyUser(await _apiService.getCurrentUser());
      _profileRetryAttempt = 0;
    } catch (e) {
      debugPrint('Erro ao carregar usuário: $e');
      if (!_hasProfile) _scheduleProfileRetry();
    } finally {
      if (mounted && !_profileReady) setState(() => _profileReady = true);
    }
  }

  /// 3 s, 6 s, 12 s, 24 s e depois a cada 30 s, ate o perfil vir.
  void _scheduleProfileRetry() {
    if (!mounted) return;
    final seconds = (3 << _profileRetryAttempt.clamp(0, 3)).clamp(3, 30);
    _profileRetryAttempt++;
    _profileRetryTimer?.cancel();
    _profileRetryTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_hasProfile) _loadUser();
    });
  }

  void _applyUser(Map<String, dynamic> user) {
    if (!mounted) return;
    _hasProfile = true;
    setState(() {
      _isAdmin = user['role'] == 'admin' || user['role'] == 'manager';
      _dailyMode = user['daily_mode'] == true;
      _mustChangePassword =
          !_passwordChanged && user['must_change_password'] == true;
      _cpf = user['cpf']?.toString();
      _profileReady = true;
    });
  }

  // Abas ja abertas nesta sessao. Cada aba so e montada no primeiro toque e
  // depois fica viva no IndexedStack. Montar todas na abertura lia o perfil
  // 4-5 vezes e disparava Dash (que recarrega a cada 30 s), Historico e
  // Gestao junto com a tela de ponto, disputando a internet do celular.
  final Set<String> _openedTabs = {'ponto'};

  List<String> get _tabIds => [
        'ponto',
        'dash',
        'historico',
        if (_isAdmin) 'gestao',
        'perfil',
      ];

  Widget _screenFor(String id) {
    switch (id) {
      case 'ponto':
        return _dailyMode ? const DailyModeScreen() : const HomeScreen();
      case 'dash':
        return const DashboardScreen();
      case 'historico':
        return const HistoryScreen();
      case 'gestao':
        return const AdminScreen();
      default:
        return const ProfileScreen();
    }
  }

  List<Widget> get _screens => [
        for (final id in _tabIds)
          KeyedSubtree(
            key: ValueKey(id),
            child: _openedTabs.contains(id)
                ? _screenFor(id)
                : const SizedBox.shrink(),
          ),
      ];

  /// Abas do menu: as mesmas no celular (barra de baixo) e no computador
  /// (menu na lateral).
  List<(IconData, String)> get _tabs => [
    (Icons.timer, 'Ponto'),
    (Icons.dashboard, 'Dash'),
    (Icons.history, 'Histórico'),
    if (_isAdmin) (Icons.admin_panel_settings, 'Gestão'),
    (Icons.person, 'Perfil'),
  ];

  /// Troca de aba pelo menu de baixo (celular) ou da lateral (computador).
  void _selectTab(int index) => setState(() {
        _selectedIndex = index;
        _openedTabs.add(_tabIds[index]);
      });

  /// A partir desta largura (tablet deitado, computador) o menu vai para a
  /// lateral e a tela ganha espaco na vertical.
  static const double _sideMenuFrom = 900;

  /// Mantem as abas abertas (e o que ja carregaram) quando a janela passa
  /// de um layout para o outro.
  final _tabsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    if (!_profileReady) {
      return const Scaffold(body: StartupLoading(from: 94, to: 99));
    }
    if (_mustChangePassword) {
      return ChangePasswordScreen(
        forced: true,
        cpf: _cpf,
        onChanged: () => setState(() {
          _mustChangePassword = false;
          _passwordChanged = true;
        }),
      );
    }
    final body = KeyedSubtree(
      key: _tabsKey,
      child: IndexedStack(index: _selectedIndex, children: [
        // No computador cada aba fica numa coluna no centro; a Gestao, com
        // listas e tabelas, mais larga.
        for (final (i, screen) in _screens.indexed)
          ContentWidth(
            maxWidth: _isAdmin && i == 3 ? ContentWidth.wide : ContentWidth.narrow,
            child: screen,
          ),
      ]),
    );
    final primary = Theme.of(context).primaryColor;

    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= _sideMenuFrom) {
          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  right: false,
                  child: NavigationRail(
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: _selectTab,
                    extended: box.maxWidth >= 1200,
                    labelType: box.maxWidth >= 1200
                        ? NavigationRailLabelType.none
                        : NavigationRailLabelType.all,
                    selectedIconTheme: IconThemeData(color: primary),
                    selectedLabelTextStyle: TextStyle(
                      color: primary,
                      fontWeight: FontWeight.w600,
                    ),
                    unselectedIconTheme: const IconThemeData(
                      color: Colors.grey,
                    ),
                    unselectedLabelTextStyle: const TextStyle(
                      color: Colors.grey,
                    ),
                    destinations: [
                      for (final (icon, label) in _tabs)
                        NavigationRailDestination(
                          icon: Icon(icon),
                          label: Text(label),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _selectedIndex,
            onTap: _selectTab,
            type: BottomNavigationBarType.fixed,
            selectedItemColor: primary,
            unselectedItemColor: Colors.grey,
            items: [
              for (final (icon, label) in _tabs)
                BottomNavigationBarItem(icon: Icon(icon), label: label),
            ],
          ),
        );
      },
    );
  }
}
