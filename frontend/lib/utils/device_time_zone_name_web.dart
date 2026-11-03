import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Nome do fuso do celular, como o navegador informa ("America/Cuiaba").
/// Null se o navegador nao disser.
String? deviceTimeZoneName() {
  try {
    final intl = globalContext.getProperty<JSObject?>('Intl'.toJS);
    if (intl == null) return null;
    final formatter = intl.callMethod<JSObject>('DateTimeFormat'.toJS);
    final options = formatter.callMethod<JSObject>('resolvedOptions'.toJS);
    final name = options.getProperty<JSAny?>('timeZone'.toJS).dartify();
    return name is String && name.isNotEmpty ? name : null;
  } catch (_) {
    return null;
  }
}
