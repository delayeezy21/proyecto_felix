import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/app.dart';

void main() {
  Future<MaterialLocalizations> pumpWith(
    WidgetTester tester,
    Locale device,
  ) async {
    late MaterialLocalizations l;
    await tester.pumpWidget(
      MaterialApp(
        locale: device,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        localeResolutionCallback: resolveAppLocale,
        home: Builder(
          builder: (context) {
            l = MaterialLocalizations.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return l;
  }

  testWidgets('calendario en español, de lunes a domingo', (tester) async {
    final l = await pumpWith(tester, const Locale('es', 'CL'));
    expect(l.firstDayOfWeekIndex, 1, reason: 'la semana parte el lunes');
    expect(l.formatMonthYear(DateTime(2026, 11)), contains('noviembre'));
    expect(l.narrowWeekdays[1], 'L');
  });

  test('un dispositivo en otro idioma usa es-CL', () {
    expect(
      resolveAppLocale(const Locale('en', 'US'), appSupportedLocales),
      const Locale('es', 'CL'),
    );
    expect(
      resolveAppLocale(const Locale('es', 'AR'), appSupportedLocales),
      const Locale('es', 'AR'),
    );
  });
}
