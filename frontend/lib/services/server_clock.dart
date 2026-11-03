import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Hora do servidor no ultimo contato com o backend (03/11/2026).
///
/// Sem internet a batida so tem o relogio do celular, e ele pode ser mexido:
/// atrasar a hora, bater a entrada e voltar a hora certa. Toda resposta do
/// backend traz a hora dele (cabecalho X-Server-Time). O app guarda a do
/// ultimo contato junto com a do celular no mesmo momento e manda as duas com
/// a batida offline. O servidor corrige a batida pelo erro do relogio e recusa
/// a que ficar antes daquele contato (backend: _offline_punch_moment).
///
/// Enquanto o app nao e fechado, conta tambem o tempo desde o contato num
/// cronometro que a hora do celular nao mexe (anchor_elapsed_ms).
class ServerClock {
  ServerClock._();

  static const String _key = 'server_clock_anchor';
  static DateTime? _server;
  static DateTime? _device;
  static final Stopwatch _sinceAnchor = Stopwatch();
  static Future<void>? _loading;

  /// Anota a hora do servidor de uma resposta do backend.
  static void note(http.BaseResponse response) {
    final server = parseServerTime(response.headers['x-server-time']);
    if (server == null) return;
    _server = server;
    _device = DateTime.now().toUtc();
    _sinceAnchor
      ..reset()
      ..start();
    unawaited(_save(server, _device!));
  }

  static DateTime? parseServerTime(String? value) {
    if (value == null || value.isEmpty) return null;
    final parsed = DateTime.tryParse(value.trim());
    if (parsed == null || !parsed.isUtc) return null;
    return parsed;
  }

  static Future<void> _save(DateTime server, DateTime device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key,
          jsonEncode({
            'server': server.toIso8601String(),
            'device': device.toIso8601String(),
          }));
    } catch (e) {
      debugPrint('Hora do servidor nao guardada: $e');
    }
  }

  static Future<void> _load() => _loading ??= () async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final raw = prefs.getString(_key);
          // Uma resposta chegou enquanto lia: ela e mais nova.
          if (raw == null || _server != null) return;
          final saved = jsonDecode(raw) as Map<String, dynamic>;
          final server = parseServerTime(saved['server']?.toString());
          final device = parseServerTime(saved['device']?.toString());
          if (server == null || device == null) return;
          _server = server;
          _device = device;
        } catch (e) {
          debugPrint('Hora do servidor guardada ilegivel: $e');
        }
      }();

  /// Campos que vao com a batida feita agora, para a fila offline guardar.
  /// Vazio se o app nunca falou com o servidor desde a atualizacao.
  static Future<Map<String, dynamic>> anchorFields() async {
    await _load();
    final server = _server;
    final device = _device;
    if (server == null || device == null) return {};
    return {
      'server_anchor': server.toIso8601String(),
      'device_anchor': device.toIso8601String(),
      // So se o contato foi nesta abertura do app: depois de fechar, o
      // cronometro recomeca do zero e nao diz nada.
      if (_sinceAnchor.isRunning)
        'anchor_elapsed_ms': _sinceAnchor.elapsedMilliseconds,
    };
  }

  /// Os campos guardados numa batida da fila, para reenviar iguais.
  static Map<String, dynamic> storedAnchorFields(Map<String, dynamic> record) {
    final server = record['server_anchor'];
    final device = record['device_anchor'];
    final elapsed = record['anchor_elapsed_ms'];
    if (server is! String || device is! String) return {};
    return {
      'server_anchor': server,
      'device_anchor': device,
      if (elapsed is num) 'anchor_elapsed_ms': elapsed.toInt(),
    };
  }

  @visibleForTesting
  static void resetForTest() {
    _server = null;
    _device = null;
    _loading = null;
    _sinceAnchor
      ..stop()
      ..reset();
  }
}

/// Cliente HTTP do backend: anota a hora do servidor de cada resposta.
class ServerClockClient extends http.BaseClient {
  ServerClockClient([http.Client? inner]) : _inner = inner ?? http.Client();

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    ServerClock.note(response);
    return response;
  }

  @override
  void close() => _inner.close();
}
