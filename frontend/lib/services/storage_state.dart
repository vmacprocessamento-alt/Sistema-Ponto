import 'storage_persistence.dart';

/// Se o navegador guarda os dados do app de forma permanente (19/11/2026):
/// pedido na abertura, informado no login (aba Usuarios). Null: nao pediu ou
/// o navegador nao tem a funcao.
class StorageState {
  StorageState._();

  static bool? persisted;

  static Future<void> init() async {
    persisted = await requestPersistentStorage();
  }
}
