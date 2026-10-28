import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/widgets/content_width.dart';

/// Celular: a tela inteira, como sempre. Computador: a coluna no centro.
void main() {
  Future<double> largura(WidgetTester tester, double tela) async {
    tester.view.physicalSize = Size(tela, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: ContentWidth(child: SizedBox.expand(key: Key('tela'))),
    ));
    return tester.getSize(find.byKey(const Key('tela'))).width;
  }

  testWidgets('no celular usa a largura toda', (tester) async {
    expect(await largura(tester, 390), 390);
  });

  testWidgets('no computador fica no centro com largura de leitura',
      (tester) async {
    expect(await largura(tester, 1400), ContentWidth.narrow);
    final x = tester.getTopLeft(find.byKey(const Key('tela'))).dx;
    expect(x, (1400 - ContentWidth.narrow) / 2);
  });
}
