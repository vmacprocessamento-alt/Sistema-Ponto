import 'package:flutter/material.dart';
import 'home_screen.dart';
import 'change_password_screen.dart';
import 'daily_mode_screen.dart';
import 'dashboard_screen.dart';
import 'history_screen.dart';
import 'admin_screen.dart';
import 'profile_screen.dart';
import '../services/api_service.dart';
import '../services/app_permission_service.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppPermissionService.requestStartupPermissions();
    });
    NotificationService.registerCurrentDevice();
    _loadUser();
  }

  Future<void> _loadUser() async {
    // Copia local primeiro (na hora, com ou sem internet); depois o perfil
    // do servidor, que traz a mudanca de modo feita pelo admin.
    try {
      final cached = await _apiService.getCachedCurrentUser();
      if (cached != null) _applyUser(cached);
    } catch (e) {
      debugPrint('Perfil local indisponível: $e');
    }
    try {
      _applyUser(await _apiService.getCurrentUser());
    } catch (e) {
      debugPrint('Erro ao carregar usuário: $e');
    } finally {
      if (mounted && !_profileReady) setState(() => _profileReady = true);
    }
  }

  void _applyUser(Map<String, dynamic> user) {
    if (!mounted) return;
    setState(() {
      _isAdmin = user['role'] == 'admin' || user['role'] == 'manager';
      _dailyMode = user['daily_mode'] == true;
      _mustChangePassword =
          !_passwordChanged && user['must_change_password'] == true;
      _cpf = user['cpf']?.toString();
      _profileReady = true;
    });
  }

  List<Widget> get _screens => [
        if (_dailyMode) const DailyModeScreen() else const HomeScreen(),
        const DashboardScreen(),
        const HistoryScreen(),
        if (_isAdmin) const AdminScreen(),
        const ProfileScreen(),
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
  void _selectTab(int index) => setState(() => _selectedIndex = index);

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
