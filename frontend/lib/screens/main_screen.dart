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
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Theme.of(context).primaryColor,
        unselectedItemColor: Colors.grey,
        items: [
          const BottomNavigationBarItem(
              icon: Icon(Icons.timer), label: 'Ponto'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard), label: 'Dash'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.history), label: 'Histórico'),
          if (_isAdmin)
            const BottomNavigationBarItem(
                icon: Icon(Icons.admin_panel_settings), label: 'Gestão'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.person), label: 'Perfil'),
        ],
      ),
    );
  }
}
