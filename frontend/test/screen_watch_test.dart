import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/utils/screen_watch.dart';

void main() {
  testWidgets('aba escondida do IndexedStack nao conta como vista',
      (tester) async {
    final watched = <String, bool>{};
    Widget probe(String name) => Builder(builder: (context) {
          watched[name] = isScreenWatched(context);
          return const SizedBox();
        });

    Future<void> show(int index) => tester.pumpWidget(MaterialApp(
          home: IndexedStack(index: index, children: [probe('ponto'), probe('dash')]),
        ));

    await show(0);
    expect(watched, {'ponto': true, 'dash': false});
    await show(1);
    expect(watched, {'ponto': false, 'dash': true});
  });

  testWidgets('app em segundo plano nao conta como vista', (tester) async {
    late BuildContext captured;
    await tester.pumpWidget(Builder(builder: (context) {
      captured = context;
      return const SizedBox();
    }));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(isScreenWatched(captured), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(isScreenWatched(captured), isTrue);
  });
}
