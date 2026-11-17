import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

void main() {
  TitleVerification v(VerificationSource s, DateTime at, {String? risk}) =>
      TitleVerification(
        source: s,
        outcome: VerificationOutcome.match,
        risk: VerificationRisk.tryParse(risk),
        createdAt: at,
      );

  test('latestVerifications deja el último de cada fuente, en orden fijo', () {
    final r1 = v(VerificationSource.rules, DateTime(2026, 11, 17, 9));
    final r2 = v(VerificationSource.rules, DateTime(2026, 11, 17, 10));
    final c = v(VerificationSource.colmevet, DateTime(2026, 11, 17, 8));
    expect(latestVerifications([c, r1, r2]), [r2, c]);
  });

  test('latestVerifications descarta resultados de rondas anteriores', () {
    final old = v(VerificationSource.rules, DateTime(2026, 11, 2));
    final now = v(VerificationSource.colmevet, DateTime(2026, 11, 17));
    expect(latestVerifications([old, now], since: DateTime(2026, 11, 16)), [
      now,
    ]);
  });

  test('valores desconocidos no rompen el parseo', () {
    expect(VerificationSource.tryParse('scraper'), isNull);
    expect(VerificationOutcome.parse('raro'), VerificationOutcome.error);
    expect(VerificationRisk.tryParse(null), isNull);
  });

  test('summary es breve y sin datos personales', () {
    final s = v(
      VerificationSource.rules,
      DateTime(2026, 11, 17),
      risk: 'medium',
    ).summary;
    expect(s, 'Reglas internas: match (riesgo medio)');
    expect(
      TitleVerification(
        source: VerificationSource.colmevet,
        outcome: VerificationOutcome.noMatch,
        createdAt: DateTime(2026, 11, 17),
      ).outcomeLabel,
      contains('voluntaria'),
    );
  });
}
