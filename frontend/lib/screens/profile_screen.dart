import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/app_version.dart';
import '../services/theme_service.dart';
import '../utils/cpf.dart';
import '../widgets/export_dialog.dart';
import 'admin_chat_list_screen.dart';
import 'change_password_screen.dart';
import 'login_screen.dart';
import '../widgets/content_width.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _apiService = ApiService();
  Map<String, dynamic>? _user;
  bool _isLoading = false;

  static const Color wineColor = Color(0xFF8B0000);

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      final user = await _apiService.getCurrentUser();
      _user = user;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao carregar dados: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar Saída'),
        content: const Text('Deseja realmente sair do aplicativo?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child:
                  const Text('Cancelar', style: TextStyle(color: Colors.grey))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sair', style: TextStyle(color: wineColor))),
        ],
      ),
    );

    if (confirm == true) {
      await _apiService.clearToken();
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    }
  }

  void _showExportDialog({bool isScratch = false, bool htmlOnly = false}) {
    showDialog(
      context: context,
      builder: (context) => ExportDialog(
        initialUser: isScratch || htmlOnly ? null : _user,
        isScratch: isScratch,
        htmlOnly: htmlOnly,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeService = Provider.of<ThemeService>(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.cardColor;
    final textColor = theme.textTheme.bodyLarge?.color;
    final isAdmin = _user?['role'] == 'admin'; // Apenas Admins reais

    if (_isLoading && _user == null) {
      return const Center(child: CircularProgressIndicator(color: wineColor));
    }

    String roleDisplay = _user?['role'] ?? '-';
    if (roleDisplay.toLowerCase() == 'intern' ||
        roleDisplay.toLowerCase() == 'estagiario') {
      roleDisplay = 'Estagiário';
    } else if (roleDisplay.toLowerCase() == 'employee') {
      roleDisplay = 'Funcionário';
    } else if (roleDisplay.toLowerCase() == 'admin') {
      roleDisplay = 'Administrador';
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              // Cabeçalho Perfil
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    CircleAvatar(
                        radius: 40,
                        backgroundColor: wineColor,
                        child: Text(_user?['name']?[0]?.toUpperCase() ?? 'U',
                            style: const TextStyle(
                                fontSize: 32,
                                color: Colors.white,
                                fontWeight: FontWeight.bold))),
                    const SizedBox(height: 16),
                    Text(_user?['name'] ?? 'Carregando...',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: textColor)),
                    Text(_user?['email'] ?? '',
                        style:
                            const TextStyle(fontSize: 14, color: Colors.grey)),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Informações
              Card(
                color: cardColor,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Column(
                  children: [
                    _buildInfoTile(
                        Icons.badge,
                        'CPF (seu login)',
                        cpfDigits(_user?['cpf']?.toString()).length == 11
                            ? formatCpf(_user?['cpf']?.toString())
                            : (_user?['cpf'] ?? '-'),
                        textColor),
                    const Divider(height: 1),
                    _buildInfoTile(Icons.access_time, 'Carga Horária Diária',
                        '${_user?['daily_hours'] ?? 8} horas', textColor),
                    const Divider(height: 1),
                    _buildInfoTile(Icons.work, 'Cargo', roleDisplay, textColor),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              _buildExportCard(
                icon: Icons.key,
                title: 'Trocar senha',
                subtitle: 'Criar uma senha nova para entrar',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ChangePasswordScreen(cpf: _user?['cpf']?.toString()),
                  ),
                ),
                textColor: textColor,
                cardColor: cardColor,
              ),
              const SizedBox(height: 12),

              // "Meus Documentos" saiu (17/10/2026): a folha de ponto vai para assinar pelo VDRod, com o link do
              // ZapSign no WhatsApp de cada um. A tela (documents_screen.dart) e a API continuam, sem entrada aqui.

              // Botões de Exportação (Cards como no backup) - VISÍVEIS APENAS PARA ADMIN
              if (isAdmin) ...[
                _buildExportCard(
                  icon: Icons.description,
                  title: 'Exportar Folha de Ponto',
                  subtitle: 'Registros de usuários do App',
                  onTap: () => _showExportDialog(isScratch: false),
                  textColor: textColor,
                  cardColor: cardColor,
                ),
                const SizedBox(height: 12),
                _buildExportCard(
                  icon: Icons.web_asset,
                  title: 'Gerar Folha de Ponto .html',
                  subtitle: 'Relatório mensal com abas e consolidado',
                  onTap: () => _showExportDialog(htmlOnly: true),
                  textColor: textColor,
                  cardColor: cardColor,
                  iconColor: Colors.teal,
                ),
                const SizedBox(height: 12),
                _buildExportCard(
                  icon: Icons.auto_fix_high,
                  title: 'Gerar Folha Avulsa (do 0)',
                  subtitle: 'Cria horários para qualquer nome',
                  onTap: () => _showExportDialog(isScratch: true),
                  textColor: textColor,
                  cardColor: cardColor,
                  iconColor: Colors.blue,
                ),
                const SizedBox(height: 12),
                StreamBuilder<int>(
                    stream: _apiService.getUnreadAdjustmentsCount(),
                    builder: (context, snapshot) {
                      final unreadCount = snapshot.data ?? 0;
                      return _buildExportCard(
                        icon: Icons.chat_bubble_outline,
                        title: 'Conversas de Ajuste',
                        subtitle: unreadCount > 0
                            ? '$unreadCount nova(s) solicitação(ões)'
                            : 'Visualizar mensagens da equipe',
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ContentWidth(child: AdminChatListScreen()))),
                        textColor: textColor,
                        cardColor: cardColor,
                        iconColor: unreadCount > 0 ? Colors.orange : wineColor,
                      );
                    }),
              ],

              const SizedBox(height: 24),

              // Modo Noturno
              SwitchListTile(
                activeThumbColor: wineColor,
                secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode,
                    color: wineColor),
                title: Text('Modo Noturno',
                    style: TextStyle(
                        color: textColor, fontWeight: FontWeight.bold)),
                value: isDark,
                onChanged: (val) => themeService.toggleTheme(),
              ),

              const SizedBox(height: 24),

              // Versao do app neste aparelho: no suporte, mostra se ja
              // atualizou (compare com a do ultimo deploy).
              Center(
                child: Text(
                  'Versão do app: ${appVersionLabel()}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),

              // Sair
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout),
                  label: const Text('SAIR DA CONTA',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: wineColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile(
      IconData icon, String label, String value, Color? textColor) {
    return ListTile(
      leading: Icon(icon, color: wineColor, size: 20),
      title:
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      subtitle: Text(value,
          style: TextStyle(
              color: textColor, fontSize: 15, fontWeight: FontWeight.bold)),
      dense: true,
    );
  }

  Widget _buildExportCard(
      {required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
      required Color? textColor,
      required Color cardColor,
      Color iconColor = wineColor}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: textColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  Text(subtitle,
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
