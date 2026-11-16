import 'package:flutter_test/flutter_test.dart';
import 'package:ponto_app/widgets/export_dialog.dart';

/// Lote da folha (16/11/2026): quem nao bateu ponto no periodo fica de fora.
void main() {
  test('sem nenhum dia de ponto fica fora do lote', () {
    expect(timesheetHasContent({'daily_records': []}), isFalse);
    expect(timesheetHasContent({}), isFalse);
    expect(
        timesheetHasContent({
          'daily_records': [
            {'date': '2026-11-03', 'total_hours': 9.0},
          ],
        }),
        isTrue);
  });

  test('modo diaria conta pelas diarias', () {
    expect(
        timesheetHasContent(
            {'daily_mode': true, 'daily_records': [], 'daily_dates': []}),
        isFalse);
    expect(
        timesheetHasContent({
          'daily_mode': true,
          'daily_records': [],
          'daily_dates': ['2026-11-03'],
        }),
        isTrue);
  });
}
