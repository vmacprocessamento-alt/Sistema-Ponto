import 'package:flutter/widgets.dart';

/// Alguem esta olhando esta tela? Nao com o app em segundo plano (ou a aba
/// do navegador escondida) nem com a tela numa aba do app que nao esta
/// aberta: o IndexedStack marca as abas escondidas (Visibility.of; versoes
/// mais antigas do Flutter desligavam o TickerMode delas).
///
/// Os recarregamentos periodicos (Dash a cada 30 s, horario do estagiario a
/// cada 90 s, sino a cada 2 min) pulam a vez quando ninguem olha: cada um le
/// o Firestore, e com o app aberto o dia inteiro isso comia a cota diaria.
bool isScreenWatched(BuildContext context) {
  final state = WidgetsBinding.instance.lifecycleState;
  final appVisible = state == null || state == AppLifecycleState.resumed;
  return appVisible &&
      Visibility.of(context) &&
      TickerMode.valuesOf(context).enabled;
}
