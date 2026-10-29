import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_update.dart';

/// Atualizacao automatica do app web, sem a equipe precisar fazer nada.
///
/// A cada deploy o service worker novo baixa a versao nova em segundo plano
/// e avisa a pagina (web/index.html marca `vmacUpdateReady`). Daqui o app
/// recarrega sozinho no primeiro momento seguro:
///  - ninguem tocou na tela nos ultimos [idleBeforeReload];
///  - nenhum dialogo, menu ou tela por cima da tela principal;
///  - nenhum campo de texto com o cursor (login, chat, motivo...);
///  - nenhuma batida, diaria ou sincronizacao da fila em andamento.
/// Na pratica isso acontece quando a pessoa tira o celular do bolso e abre o
/// app (antes do primeiro toque) ou quando o app fica parado na tela de
/// ponto. Se o momento seguro nao chega em [bannerAfter] (tela de chat
/// aberta, por exemplo), aparece a barra "Nova versao do app" com o botao
/// ATUALIZAR (widgets/update_banner.dart).
class UpdateService with WidgetsBindingObserver {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const Duration idleBeforeReload = Duration(seconds: 10);
  static const Duration bannerAfter = Duration(seconds: 20);
  static const Duration _tickEvery = Duration(seconds: 2);

  /// Mostra a barra "Nova versao do app" (atualizacao pronta, mas a tela
  /// esta em uso).
  final ValueNotifier<bool> showBanner = ValueNotifier(false);

  /// Vai no MaterialApp: conta as telas e dialogos abertos por cima da
  /// principal.
  final RouteDepthObserver navigatorObserver = RouteDepthObserver();

  final List<bool Function()> _busyChecks = [];
  late DateTime _lastInteraction = clock();
  DateTime? _readySince;
  Timer? _timer;
  bool _started = false;
  bool _applying = false;
  // O index.html recusou a recarga automatica (trava contra loop): daqui em
  // diante so pelo botao da barra.
  bool _autoBlocked = false;

  @visibleForTesting
  DateTime Function() clock = DateTime.now;
  @visibleForTesting
  bool Function() updateReady = isAppUpdateReady;
  @visibleForTesting
  bool Function({required bool force}) apply = applyAppUpdate;

  /// Liga a vigilancia (so no web, chamado em main.dart).
  void start() {
    if (_started) return;
    _started = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_tickEvery, (_) => tick());
  }

  @visibleForTesting
  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
  }

  @visibleForTesting
  void resetForTest() {
    stop();
    _busyChecks.clear();
    navigatorObserver.depth = 0;
    _readySince = null;
    _applying = false;
    _autoBlocked = false;
    showBanner.value = false;
    clock = DateTime.now;
    updateReady = isAppUpdateReady;
    apply = applyAppUpdate;
    _lastInteraction = clock();
  }

  /// [check] devolve true enquanto ha algo que uma recarga interromperia
  /// (batida em andamento, por exemplo). Quem registra remove no dispose.
  void addBusyCheck(bool Function() check) => _busyChecks.add(check);

  void removeBusyCheck(bool Function() check) => _busyChecks.remove(check);

  /// Toque, arrasto, rolagem ou tecla: a pessoa esta usando a tela.
  void markInteraction() => _lastInteraction = clock();

  void _onPointer(PointerEvent event) {
    // Passar o mouse por cima (hover) nao conta: so toque, arrasto e rolagem.
    if (event is PointerDownEvent ||
        event is PointerMoveEvent ||
        event is PointerUpEvent ||
        event is PointerSignalEvent) {
      markInteraction();
    }
  }

  bool _onKey(KeyEvent event) {
    markInteraction();
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Voltou para o app: aplica ja, antes do primeiro toque.
    if (state == AppLifecycleState.resumed) tick();
  }

  bool get _textFieldFocused {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool get _busy {
    for (final check in List.of(_busyChecks)) {
      try {
        if (check()) return true;
      } catch (_) {
        // Tela que ja saiu: ignora.
      }
    }
    return false;
  }

  /// Da para recarregar agora sem atrapalhar ninguem.
  bool get isSafeMoment =>
      clock().difference(_lastInteraction) >= idleBeforeReload &&
      navigatorObserver.depth <= 1 &&
      !_textFieldFocused &&
      !_busy;

  @visibleForTesting
  void tick() {
    if (_applying || !updateReady()) return;
    final now = clock();
    _readySince ??= now;
    if (!_autoBlocked && isSafeMoment) {
      _apply(force: false);
      return;
    }
    if (now.difference(_readySince!) >= bannerAfter) showBanner.value = true;
  }

  /// Toque em ATUALIZAR na barra.
  void applyNow() => _apply(force: true);

  void _apply({required bool force}) {
    _applying = true;
    final reloading = apply(force: force);
    if (reloading) return;
    _applying = false;
    if (!force) _autoBlocked = true;
    showBanner.value = true;
  }
}

/// Quantas rotas (telas, dialogos, menus) estao abertas no navegador
/// principal. 1 = so a tela principal.
class RouteDepthObserver extends NavigatorObserver {
  int depth = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => depth++;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (depth > 0) depth--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (depth > 0) depth--;
  }
}
