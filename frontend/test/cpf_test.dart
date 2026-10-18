import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/cpf.dart';

void main() {
  test('isValidCpf confere os digitos verificadores', () {
    // Os mesmos casos de CpfRulesTest (backend/test_work_schedule.py).
    expect(isValidCpf('52998224725'), isTrue);
    expect(isValidCpf('529.982.247-25'), isTrue);
    expect(isValidCpf('111.444.777-35'), isTrue);
    for (final value in [
      '52998224724',
      '11111111111',
      '5299822472',
      '',
      null,
      'abcdefghijk',
    ]) {
      expect(isValidCpf(value), isFalse, reason: '$value');
    }
  });

  test('formatCpf com traco antes dos dois ultimos digitos', () {
    expect(formatCpf('52998224725'), '529.982.247-25');
    // O cadastro antigo gravava "529.982.247.25".
    expect(formatCpf('529.982.247.25'), '529.982.247-25');
    expect(formatCpf('5299'), '529.9');
    expect(formatCpf('529982247251234'), '529.982.247-25');
    expect(cpfDigits('529.982.247-25'), '52998224725');
  });

  test('mascara do campo', () {
    final value = CpfInputFormatter().formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: '52998224725'),
    );
    expect(value.text, '529.982.247-25');
    expect(value.selection.baseOffset, value.text.length);
  });
}
