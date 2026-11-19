import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Pede ao navegador para guardar os dados do site de forma permanente
/// (19/11/2026). Sem isso o Chrome do Android apaga os dados de sites quando o
/// celular fica com pouco espaco, e com eles vao a sessao (a pessoa cai no
/// login e nao lembra a senha) e a fila de batidas offline. Com o app
/// instalado o Chrome costuma conceder sozinho. True: protegido; false:
/// recusado; null: o navegador nao tem a funcao.
Future<bool?> requestPersistentStorage() async {
  try {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    final storage = navigator?.getProperty<JSObject?>('storage'.toJS);
    if (storage == null || !storage.has('persist')) return null;
    final persisted = storage.has('persisted')
        ? await storage
            .callMethod<JSPromise<JSBoolean>>('persisted'.toJS)
            .toDart
        : null;
    if (persisted?.toDart == true) return true;
    final granted =
        await storage.callMethod<JSPromise<JSBoolean>>('persist'.toJS).toDart;
    return granted.toDart;
  } catch (_) {
    return null;
  }
}
