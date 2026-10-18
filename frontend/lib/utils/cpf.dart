import 'package:flutter/services.dart';

// CPF: o login do app e o identificador do cadastro. Mesmas regras de
// cpf_digits / is_valid_cpf / format_cpf (backend/main.py).

/// So os digitos de [value].
String cpfDigits(String? value) => (value ?? '').replaceAll(RegExp(r'\D'), '');

/// CPF de 11 digitos com os dois digitos verificadores certos.
bool isValidCpf(String? value) {
  final digits = cpfDigits(value);
  if (digits.length != 11 || RegExp(r'^(\d)\1{10}$').hasMatch(digits)) {
    return false;
  }
  for (final size in [9, 10]) {
    var total = 0;
    for (var i = 0; i < size; i++) {
      total += int.parse(digits[i]) * (size + 1 - i);
    }
    if ((total * 10) % 11 % 10 != int.parse(digits[size])) return false;
  }
  return true;
}

/// 000.000.000-00 (ou o que ja da para formatar enquanto digita).
String formatCpf(String? value) {
  final digits = cpfDigits(value);
  final limited = digits.length > 11 ? digits.substring(0, 11) : digits;
  final buffer = StringBuffer();
  for (var i = 0; i < limited.length; i++) {
    if (i == 3 || i == 6) buffer.write('.');
    if (i == 9) buffer.write('-');
    buffer.write(limited[i]);
  }
  return buffer.toString();
}

/// Mascara do CPF no campo de texto.
class CpfInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = formatCpf(newValue.text);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
