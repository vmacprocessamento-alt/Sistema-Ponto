import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../utils/device_label.dart';

/// "iPhone · app instalado", "Computador · navegador"... (utils/device_label.dart).
String currentDeviceLabel() {
  try {
    final navigator = globalContext.getProperty<JSObject>('navigator'.toJS);
    final userAgent =
        navigator.getProperty<JSAny?>('userAgent'.toJS).dartify()?.toString() ??
            '';
    final maxTouchPoints =
        (navigator.getProperty<JSAny?>('maxTouchPoints'.toJS).dartify() as num?)
                ?.toInt() ??
            0;
    // Aberto pelo icone na tela inicial: display-mode standalone (Android,
    // computador) ou navigator.standalone (iPhone).
    var installed =
        navigator.getProperty<JSAny?>('standalone'.toJS).dartify() == true;
    if (!installed) {
      final query = globalContext.callMethod<JSObject>(
          'matchMedia'.toJS, '(display-mode: standalone)'.toJS);
      installed = query.getProperty<JSAny?>('matches'.toJS).dartify() == true;
    }
    return describeDevice(userAgent,
        installed: installed, maxTouchPoints: maxTouchPoints);
  } catch (_) {
    return '';
  }
}
