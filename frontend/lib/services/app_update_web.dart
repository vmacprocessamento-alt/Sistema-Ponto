import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// Ponte com o web/index.html: vmacUpdateReady (a versao nova ja foi baixada
// pelo service worker), vmacApplyUpdate (recarrega a pagina) e
// vmacCheckForUpdate (pergunta ao servidor se ha versao nova).

/// Pede a checagem de versao nova. O index.html limita a uma a cada 5 min:
/// chamar a cada troca de aba ou batida nao gera requisicao a mais.
void requestAppUpdateCheck() {
  try {
    if (globalContext.has('vmacCheckForUpdate')) {
      globalContext.callMethod<JSAny?>('vmacCheckForUpdate'.toJS);
    }
  } catch (_) {
    // Sem service worker: nada a conferir.
  }
}

bool isAppUpdateReady() {
  try {
    return globalContext.getProperty<JSAny?>('vmacUpdateReady'.toJS).dartify() ==
        true;
  } catch (_) {
    return false;
  }
}

/// Recarrega na versao nova. Devolve false quando o index.html recusou (trava
/// contra recarga em loop) e a pagina segue como esta.
bool applyAppUpdate({required bool force}) {
  try {
    if (!globalContext.has('vmacApplyUpdate')) return false;
    return globalContext
            .callMethod<JSAny?>('vmacApplyUpdate'.toJS, force.toJS)
            .dartify() ==
        true;
  } catch (_) {
    return false;
  }
}
