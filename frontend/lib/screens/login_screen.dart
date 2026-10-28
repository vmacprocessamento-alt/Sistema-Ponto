import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/app_permission_service.dart';
import '../utils/cpf.dart';
import 'main_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();
  final _apiService = ApiService();
  bool _isLoading = false;
  bool _obscurePassword = true;
  // O acesso e pelo CPF. O e-mail fica de reserva: conta antiga sem CPF no
  // cadastro (ex.: admin) ou backend fora do ar (o login por CPF passa por ele).
  bool _useEmail = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppPermissionService.requestStartupPermissions();
    });
    _fillLastLogin();
  }

  // Abre com o ultimo CPF (ou e-mail) usado neste aparelho ja preenchido.
  Future<void> _fillLastLogin() async {
    final last = await _apiService.getLastLogin();
    if (!mounted || last == null || _loginController.text.isNotEmpty) return;
    setState(() {
      _useEmail = last.contains('@');
      _loginController.text = _useEmail ? last : formatCpf(last);
    });
  }

  void _toggleEmail() {
    setState(() {
      _useEmail = !_useEmail;
      _loginController.clear();
    });
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    // Lembra o login ja na tentativa (com ou sem internet), nao so no login
    // que deu certo.
    await _apiService.saveLastLogin(_loginController.text);

    try {
      await _apiService.loginWithCpf(
        _loginController.text,
        _passwordController.text,
      );

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainScreen()),
        );
      }
    } catch (e) {
      debugPrint('ERRO NO LOGIN: $e');
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Falha no Acesso'),
            content: Text(e.toString().replaceAll('Exception:', '').trim()),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showForgotPasswordDialog() {
    final emailController = TextEditingController(
        text: _useEmail ? _loginController.text.trim() : '');
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Esqueceu a senha?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Fale com o administrador: ele redefine a sua senha e, ao '
                'entrar, você cria uma nova.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Se você tem e-mail no cadastro, também pode receber um link '
                'para criar a senha:',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emailController,
                decoration: const InputDecoration(
                  labelText: 'E-mail',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (emailController.text.isNotEmpty) {
                // Pegos antes da espera: depois dela o dialogo pode ter
                // fechado e o context dele nao vale mais.
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(dialogContext);
                try {
                  await _apiService.resetPassword(emailController.text);
                  if (dialogContext.mounted) navigator.pop();
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('E-mail de recuperação enviado! Verifique sua caixa de entrada.'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } catch (e) {
                  messenger.showSnackBar(
                    SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
                  );
                }
              }
            },
            child: const Text('Enviar link'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Image.asset(
                    'assets/images/logo.jpg',
                    height: 150,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'VMac Ponto',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Entre com seu CPF e senha',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                  ),
                  const SizedBox(height: 48),
                  TextFormField(
                    // A chave troca o campo inteiro (teclado e mascara) ao
                    // alternar entre CPF e e-mail.
                    key: ValueKey(_useEmail),
                    controller: _loginController,
                    keyboardType: _useEmail
                        ? TextInputType.emailAddress
                        : TextInputType.number,
                    inputFormatters: _useEmail ? null : [CpfInputFormatter()],
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: _useEmail ? 'E-mail' : 'CPF',
                      hintText: _useEmail ? null : '000.000.000-00',
                      prefixIcon: Icon(_useEmail
                          ? Icons.email_outlined
                          : Icons.badge_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    validator: (value) {
                      final text = value?.trim() ?? '';
                      if (_useEmail) {
                        if (text.isEmpty) return 'Por favor, insira seu e-mail';
                        if (!text.contains('@')) return 'E-mail inválido';
                        return null;
                      }
                      if (text.isEmpty) return 'Por favor, insira seu CPF';
                      if (!isValidCpf(text)) return 'CPF inválido';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Senha',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Por favor, insira sua senha';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => _isLoading ? null : _login(),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _showForgotPasswordDialog,
                      child: const Text('Esqueceu a senha?'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            'Entrar',
                            style: TextStyle(fontSize: 16),
                          ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Primeiro acesso: entre com o seu CPF e a senha que o '
                    'administrador passou.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  TextButton(
                    onPressed: _toggleEmail,
                    child: Text(_useEmail ? 'Entrar com CPF' : 'Entrar com e-mail',
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _loginController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
