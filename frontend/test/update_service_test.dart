import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/services/update_service.dart';
import 'package:ponto_app/widgets/update_banner.dart';

/// Atualizacao automatica: recarrega sozinho so quando ninguem esta usando a
/// tela; senao mostra a barra "Nova versao do app".
void main() {
  final service = UpdateService.instance;
  late DateTime now;
  late bool ready;
  late List<bool> applied; // force de cada recarga pedida
  late bool reloadAccepted;

  setUp(() {
    service.resetForTest();
    now = DateTime(2026, 10, 29, 8);
    ready = false;
    applied = [];
    reloadAccepted = true;
    service
      ..clock = (() => now)
      ..updateReady = (() => ready)
      ..apply = ({required bool force}) {
        applied.add(force);
        return reloadAccepted;
      };
    service.markInteraction();
  });

  tearDown(service.resetForTest);

  Widget app({Widget? home}) => MaterialApp(
        navigatorObservers: [service.navigatorObserver],
        builder: (context, child) => UpdateBanner(child: child!),
        home: home ?? const Scaffold(body: Text('ponto')),
      );

  void idle() => now = now.add(UpdateService.idleBeforeReload);

  testWidgets('sem versao nova nao faz nada', (tester) async {
    await tester.pumpWidget(app());
    idle();
    service.tick();
    expect(applied, isEmpty);
    expect(service.showBanner.value, isFalse);
  });

  testWidgets('versao nova e tela parada: recarrega sozinho', (tester) async {
    await tester.pumpWidget(app());
    ready = true;
    service.tick();
    expect(applied, isEmpty, reason: 'tocou na tela agora ha pouco');
    idle();
    service.tick();
    expect(applied, [false]);
    // Recarga pedida: nao pede de novo.
    service.tick();
    expect(applied, [false]);
  });

  testWidgets('dialogo aberto: espera, e mostra a barra depois de um tempo',
      (tester) async {
    await tester.pumpWidget(app(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const AlertDialog(content: Text('motivo')),
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    ready = true;
    idle();
    service.tick();
    expect(applied, isEmpty);
    expect(service.showBanner.value, isFalse);

    now = now.add(UpdateService.bannerAfter);
    service.tick();
    expect(applied, isEmpty);
    expect(service.showBanner.value, isTrue);
    await tester.pump();
    expect(find.text('Nova versão do app disponível.'), findsOneWidget);

    // Fechou o dialogo e ficou parado: recarrega sozinho.
    Navigator.of(tester.element(find.text('motivo'))).pop();
    await tester.pumpAndSettle();
    idle();
    service.tick();
    expect(applied, [false]);
  });

  testWidgets('campo de texto com o cursor: nao recarrega', (tester) async {
    await tester.pumpWidget(app(home: const Scaffold(body: TextField())));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    ready = true;
    idle();
    service.tick();
    expect(applied, isEmpty);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    service.tick();
    expect(applied, [false]);
  });

  testWidgets('batida em andamento: nao recarrega', (tester) async {
    await tester.pumpWidget(app());
    var punching = true;
    bool check() => punching;
    service.addBusyCheck(check);
    ready = true;
    idle();
    service.tick();
    expect(applied, isEmpty);

    punching = false;
    service.tick();
    expect(applied, [false]);
    service.removeBusyCheck(check);
  });

  testWidgets('toque na barra atualiza na hora', (tester) async {
    await tester.pumpWidget(app());
    service.showBanner.value = true;
    await tester.pump();
    await tester.tap(find.text('ATUALIZAR'));
    expect(applied, [true]);
  });

  testWidgets('recarga automatica recusada (trava de loop): so pela barra',
      (tester) async {
    await tester.pumpWidget(app());
    reloadAccepted = false;
    ready = true;
    idle();
    service.tick();
    expect(applied, [false]);
    expect(service.showBanner.value, isTrue);
    // Nao fica tentando sozinho de novo.
    service.tick();
    service.tick();
    expect(applied, [false]);
  });

  testWidgets('toque, arrasto e tecla contam como uso; passar o mouse nao',
      (tester) async {
    service.start();
    await tester.pumpWidget(app(home: const Scaffold(body: Text('ponto'))));
    ready = true;
    idle();
    await tester.tap(find.text('ponto'));
    service.tick();
    expect(applied, isEmpty, reason: 'acabou de tocar');

    idle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(10, 10));
    service.tick();
    expect(applied, [false]);
    // O timer periodico do start() precisa parar antes do fim do teste.
    service.stop();
  });
}
