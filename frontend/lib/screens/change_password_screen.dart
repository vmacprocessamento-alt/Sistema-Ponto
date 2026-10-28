import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../utils/cpf.dart';
import 'login_screen.dart';

/// Criar a senha (primeiro acesso, ou depois de o admin redefinir: [forced],
/// sem sair daqui a nao ser pela conta) ou trocar a senha pelo Perfil.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({
    super.key,
    this.forced = false,
    this.cpf,
    this.onChanged,
  });

  final bool forced;
  // CPF da pessoa: nao vale como senha.
  final String? cpf;
  final VoidCallback? onChanged;

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  static const Color wineColor = Color(0xFF8B0000);

  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _apiService = ApiService();
  bool _obscure = true;
  bool _saving = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.length < 6) return 'Use pelo menos 6 caracteres.';
    if (password == ApiService.legacyDefaultPassword) {
      return 'Escolha uma senha diferente da senha padrão.';
    }
    final cpf = cpfDigits(widget.cpf);
    if (cpf.isNotEmpty && password == cpf) return 'Não use o CPF como senha.';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await _apiService.changeOwnPassword(_passwordController.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Senha salva!'),
        backgroundColor: Colors.green,
      ));
      if (widget.onChanged != null) {
        widget.onChanged!();
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Não deu para salvar a senha: ${e.toString().replaceAll('Exception:', '').trim()}'),
        backgroundColor: wineColor,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _logout() async {
    await _apiService.clearToken();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  InputDecoration _decoration(String label) => InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          icon: Icon(_obscure
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.forced,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !widget.forced,
          title: Text(widget.forced ? 'Crie sua senha' : 'Trocar senha',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            if (widget.forced)
              TextButton(onPressed: _logout, child: const Text('Sair')),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.key, size: 56, color: wineColor),
                      const SizedBox(height: 16),
                      Text(
                        widget.forced
                            ? 'Você entrou com a senha que o administrador '
                                'passou. Para continuar, '
                                'crie uma senha só sua: é com ela e o seu CPF '
                                'que você vai entrar daqui para frente.'
                            : 'Digite a nova senha duas vezes.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscure,
                        autofocus: true,
                        decoration: _decoration('Nova senha'),
                        validator: _validatePassword,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirmController,
                        obscureText: _obscure,
                        decoration: _decoration('Repita a nova senha'),
                        validator: (value) => value != _passwordController.text
                            ? 'As senhas não são iguais.'
                            : null,
                        onFieldSubmitted: (_) => _saving ? null : _save(),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: wineColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _saving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Text('Salvar senha',
                                style: TextStyle(fontSize: 16)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
