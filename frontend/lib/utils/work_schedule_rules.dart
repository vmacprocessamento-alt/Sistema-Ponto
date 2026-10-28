DateTime scheduleTime(DateTime day, dynamic value) {
  final parts = value.toString().split(':');
  return DateTime(
    day.year,
    day.month,
    day.day,
    int.tryParse(parts.first) ?? 0,
    parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
  );
}

/// Estagiario pelo cadastro: papel intern/estag ou cargo com "estag". Mesma
/// regra do backend (_is_intern_profile) e do firestore.rules (isIntern):
/// se o app discordar, a batida vai pelo caminho errado e as regras recusam.
bool isInternProfile(Map<String, dynamic>? user) {
  final role = '${user?['role'] ?? ''}'.toLowerCase();
  final jobTitle = '${user?['job_title'] ?? ''}'.toLowerCase();
  return role.contains('intern') ||
      role.contains('estag') ||
      jobTitle.contains('estag');
}

bool isInternWorkday(DateTime attempted) {
  return attempted.weekday >= DateTime.monday &&
      attempted.weekday <= DateTime.friday;
}

bool isInternStartWithinSchedule(
  DateTime attempted,
  Map<String, dynamic> schedule,
) {
  if (!isInternWorkday(attempted)) return false;
  final lower = scheduleTime(attempted, schedule['start_allowed_from']);
  final upper = scheduleTime(attempted, schedule['start_allowed_until']);
  return !attempted.isBefore(lower) && !attempted.isAfter(upper);
}
