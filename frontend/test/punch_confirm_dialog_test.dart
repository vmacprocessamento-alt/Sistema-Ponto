import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/widgets/punch_confirm_dialog.dart';

/// Confirmacao da batida (04/11/2026): toque sem querer nao registra ponto.
void main() {
  Future<bool?> open(WidgetTester tester, {String? warning}) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await confirmPunch(
            context,
            label: 'Entrada',
            at: DateTime(2026, 11, 3, 21, 24),
            warning: warning,
          ),
          child: const Text('bater'),
        ),
      ),
    ));
    await tester.tap(find.text('bater'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('mostra o tipo e a hora; Confirmar registra', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await confirmPunch(context,
              label: 'Entrada', at: DateTime(2026, 11, 3, 21, 24)),
          child: const Text('bater'),
        ),
      ),
    ));
    await tester.tap(find.text('bater'));
    await tester.pumpAndSettle();
    expect(find.text('Registrar Entrada?'), findsOneWidget);
    expect(find.text('21:24'), findsOneWidget);
    await tester.tap(find.text('Confirmar Entrada'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('Cancelar nao registra', (tester) async {
    await open(tester);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Registrar Entrada?'), findsNothing);
  });

  testWidgets('aviso de turno ja encerrado hoje', (tester) async {
    await open(tester, warning: 'Você já encerrou um turno hoje.');
    expect(find.text('Você já encerrou um turno hoje.'), findsOneWidget);
  });
}
