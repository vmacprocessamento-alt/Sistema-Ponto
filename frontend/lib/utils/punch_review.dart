import 'time_zone.dart';

/// ABA CONFERENCIA DA GESTAO (03/11/2026). Por que uma batida merece um olhar
/// do gestor. Vazio: nada a conferir (ja conferida, lancada ou corrigida pelo
/// gestor, ou calculada pelo sistema).
///
/// O servidor ja recusa o que da para provar (relogio atrasado depois do
/// ultimo contato, offline com mais de 48 horas, GPS fora do Brasil). Aqui
/// fica o que passou mas pode esconder um "jeitinho": batida offline enviada
/// muito depois, relogio do celular diferente do servidor, outro fuso, fuso
/// trocado no meio do turno.
///
/// Sem GPS nao entra: o servidor ja recusa batida sem localizacao, e as que
/// ficam sem ela sao de antes da 0.7 (GPS opcional) ou feitas pelo sistema (o
/// "Fechar ponto" no horario programado do estagiario); apareciam todo dia.
List<String> reviewReasons(Map<String, dynamic> record) {
  if (record['reviewed_at'] != null) return const [];
  final id = record['id']?.toString() ?? '';
  if (record['created_by_admin'] == true ||
      record['edited_by_admin'] == true ||
      record['auto_closed'] == true ||
      id.startsWith('forgot_') ||
      id.startsWith('autoclose_')) {
    return const [];
  }

  final reasons = <String>[];
  if (record['offline_without_anchor'] == true) {
    reasons.add('Offline de app antigo: relógio do celular sem conferência');
  }
  final delay = record['offline_delay_minutes'];
  if (record['synced_from_offline'] == true && delay is num && delay >= 30) {
    reasons.add('Batida offline enviada ${_duration(delay.toInt())} depois');
  }
  final skew = record['clock_skew_seconds'];
  if (skew is num && skew.abs() >= 300) {
    final minutes = (skew.abs() / 60).round();
    reasons.add('Relógio do celular ${_duration(minutes)} '
        '${skew > 0 ? 'adiantado' : 'atrasado'}');
  } else {
    final deviceGap = _deviceGapMinutes(record);
    if (deviceGap != null && deviceGap >= 5) {
      reasons.add('Hora do celular diferente da registrada '
          '(${_hhmm(record['device_timestamp'])})');
    }
  }
  final deviceOffset = record['device_utc_offset_minutes'];
  if (deviceOffset is num) {
    reasons.add('Fuso do celular trocado durante o turno '
        '(${timeZoneLabel(deviceOffset, null) ?? 'UTC-3'} na batida)');
  }
  // So na entrada: ela define o fuso do turno, e pausas e saida seguem nele.
  // Em todas, quem trabalha em MT encheria a lista todo dia.
  final zone = record['record_type'] == 'check_in'
      ? timeZoneLabel(record['utc_offset_minutes'], record['time_zone'])
      : null;
  if (zone != null) {
    reasons.add('Fora do fuso de Brasília: $zone');
  }
  return reasons;
}

/// Motivo de uma batida recusada pelo servidor (punch_rejections.reason).
String rejectionReasonLabel(String? reason) {
  switch (reason) {
    case 'clock_moved_back':
    case 'invalid_anchor':
      return 'Hora do celular atrasada depois do último contato';
    case 'clock_ahead':
    case 'future':
      return 'Hora do celular adiantada (batida no futuro)';
    case 'too_old':
      return 'Offline com mais de 48 horas';
    case 'clock_far_online':
      return 'Hora do celular muito diferente do servidor';
    case 'location_outside_brazil':
      return 'Localização fora do Brasil';
    default:
      return 'Recusada pelo servidor';
  }
}

/// Link do mapa da localizacao da batida; null sem GPS.
Uri? recordMapUri(Map<String, dynamic> record) {
  final lat = record['latitude'];
  final lng = record['longitude'];
  if (lat is! num || lng is! num) return null;
  return Uri.https('www.google.com', '/maps/search/', {
    'api': '1',
    'query': '$lat,$lng',
  });
}

int? _deviceGapMinutes(Map<String, dynamic> record) {
  final device = DateTime.tryParse(record['device_timestamp']?.toString() ?? '');
  final stored = DateTime.tryParse(record['timestamp']?.toString() ?? '');
  if (device == null || stored == null) return null;
  return device.difference(stored).inMinutes.abs();
}

String _hhmm(Object? value) {
  final moment = DateTime.tryParse(value?.toString() ?? '');
  if (moment == null) return '?';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(moment.day)}/${two(moment.month)} '
      '${two(moment.hour)}:${two(moment.minute)}';
}

String _duration(int minutes) {
  if (minutes < 60) return '$minutes min';
  final days = minutes ~/ 1440;
  final hours = (minutes % 1440) ~/ 60;
  final rest = minutes % 60;
  if (days > 0) {
    return hours == 0
        ? '$days ${days == 1 ? 'dia' : 'dias'}'
        : '$days ${days == 1 ? 'dia' : 'dias'} e ${hours}h';
  }
  return rest == 0 ? '${hours}h' : '${hours}h${rest.toString().padLeft(2, '0')}';
}
