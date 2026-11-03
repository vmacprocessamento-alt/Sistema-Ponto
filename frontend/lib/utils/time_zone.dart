import 'device_time_zone_name.dart';

/// Fuso do celular que vai junto com a hora da batida (03/11/2026).
///
/// O app manda a hora de parede do celular, sem fuso; o servidor a lia como
/// de Brasilia. Em Mato Grosso (UTC-4) a batida das 07:30 chegava como 07:30
/// de Brasilia, uma hora antes do relogio do servidor, e era recusada. Com o
/// fuso o servidor compara o momento certo e grava a hora local de onde a
/// pessoa bateu (07:30 em MT).
///
/// 'utc_offset_minutes': minutos a leste de UTC (UTC-4 = -240), do momento
/// [at]. 'time_zone': o nome do fuso no navegador ("America/Cuiaba"), quando
/// ele informa. A fila offline guarda os dois junto com a batida: ela pode
/// sincronizar depois, ja de volta a Brasilia.
Map<String, dynamic> deviceTimeZoneFields([DateTime? at]) {
  final moment = at ?? DateTime.now();
  final name = deviceTimeZoneName();
  return {
    'utc_offset_minutes': moment.timeZoneOffset.inMinutes,
    if (name != null && name.isNotEmpty) 'time_zone': name,
  };
}

/// O fuso guardado num ponto (ou numa batida da fila), para reenviar igual.
/// Vazio quando o ponto e de antes do campo existir: o servidor usa Brasilia.
Map<String, dynamic> storedTimeZoneFields(Map<String, dynamic> record) {
  final offset = record['utc_offset_minutes'];
  final name = record['time_zone'];
  return {
    if (offset is num) 'utc_offset_minutes': offset.toInt(),
    if (offset is num && name is String && name.isNotEmpty) 'time_zone': name,
  };
}

/// "Cuiaba (UTC-4)" para ponto batido fora do fuso de Brasilia; null para
/// Brasilia (UTC-3) e para ponto sem fuso.
String? timeZoneLabel(Object? offsetMinutes, Object? zoneName) {
  if (offsetMinutes is! num) return null;
  final minutes = offsetMinutes.toInt();
  if (minutes == -180) return null;
  final hours = (minutes.abs() ~/ 60).toString();
  final rest = minutes.abs() % 60;
  final utc = 'UTC${minutes < 0 ? '-' : '+'}$hours'
      '${rest == 0 ? '' : ':${rest.toString().padLeft(2, '0')}'}';
  final city = zoneName is String && zoneName.contains('/')
      ? zoneName.split('/').last.replaceAll('_', ' ')
      : null;
  return city == null ? utc : '$city ($utc)';
}
