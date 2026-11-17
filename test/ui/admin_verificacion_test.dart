// Verificación asistida del título en la revisión del admin
// (docs/verificacion-automatica.md): sugiere chequeos, el admin decide, y el
// flujo manual sigue funcionando si la verificación falla o está apagada.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/vet_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeVetRepository vets;

  final at = DateTime(2026, 11, 17, 10);
  TitleVerification rules({Set<String> suggested = const {'university'}}) =>
      TitleVerification(
        source: VerificationSource.rules,
        outcome: VerificationOutcome.match,
        risk: VerificationRisk.low,
        suggestedChecks: suggested,
        createdAt: at,
      );
  TitleVerification colmevet(VerificationOutcome o) => TitleVerification(
    source: VerificationSource.colmevet,
    outcome: o,
    suggestedChecks: o == VerificationOutcome.match ? {'colmevet'} : {},
    createdAt: at,
  );

  setUp(() {
    auth = FakeAuthRepository(userId: 'admin');
    profiles = FakeProfileRepository(
      auth,
      accounts: {
        'admin': const Account(role: AppRole.admin, displayName: 'admin'),
      },
    );
    vets =
        FakeVetRepository(
            profile: VetProfile(
              userId: 'v1',
              displayName: 'Dra. Vera',
              status: VetStatus.pending,
              university: 'Universidad de Chile',
              graduationYear: 2015,
              declarationAcceptedAt: DateTime(2026, 11, 16),
              submittedAt: DateTime(2026, 11, 16),
            ),
          )
          ..pending = [
            VetApplicationSummary(
              userId: 'v1',
              displayName: 'Dra. Vera',
              submittedAt: DateTime(2026, 11, 16),
            ),
          ];
  });

  Future<void> openReview(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 3000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, vets: vets),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('application-v1')));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  bool checked(WidgetTester tester, String key) =>
      tester.widget<CheckboxListTile>(find.byKey(Key('check-$key'))).value!;

  FilledButton approve(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('review-approve')));

  testWidgets('muestra fuente, resultado y riesgo, y precompleta lo sugerido', (
    tester,
  ) async {
    vets.verifications = [rules(), colmevet(VerificationOutcome.match)];
    await openReview(tester);

    expect(find.byKey(const Key('verification-rules')), findsOneWidget);
    expect(find.byKey(const Key('verification-colmevet')), findsOneWidget);
    expect(find.textContaining('Riesgo bajo'), findsOneWidget);
    expect(find.textContaining('17-11-2026 10:00'), findsWidgets);

    expect(checked(tester, 'university'), isTrue);
    expect(checked(tester, 'colmevet'), isTrue);
    expect(find.byKey(const Key('suggested-university')), findsOneWidget);
    // Nunca se precompletan los chequeos que exigen a una persona.
    expect(checked(tester, 'name'), isFalse);
    expect(checked(tester, 'code'), isFalse);
    expect(approve(tester).onPressed, isNull, reason: 'el admin decide');
  });

  testWidgets('el admin puede desmarcar una sugerencia y queda en las notas', (
    tester,
  ) async {
    vets.verifications = [rules()];
    await openReview(tester);
    await tap(tester, 'check-university');
    expect(checked(tester, 'university'), isFalse);

    await tap(tester, 'check-name');
    await tap(tester, 'check-university');
    await tap(tester, 'check-code');
    await tap(tester, 'review-approve');
    final notes = vets.reviews.single.$4!;
    expect(notes, contains('Verificación automática: Reglas internas: match'));
    expect(notes.length, lessThanOrEqualTo(1000));
  });

  testWidgets('sin coincidencia en COLMEVET no es una alerta ni marca nada', (
    tester,
  ) async {
    vets.verifications = [
      rules(suggested: {}),
      colmevet(VerificationOutcome.noMatch),
    ];
    await openReview(tester);
    expect(find.textContaining('la colegiatura es voluntaria'), findsOneWidget);
    expect(checked(tester, 'colmevet'), isFalse);
    expect(checked(tester, 'university'), isFalse);
  });

  testWidgets('ejecutar la verificación refresca y aplica las sugerencias', (
    tester,
  ) async {
    vets.nextVerificationResults = [rules()];
    await openReview(tester);
    expect(find.byKey(const Key('verification-empty')), findsOneWidget);
    expect(checked(tester, 'university'), isFalse);

    await tap(tester, 'run-verification');
    expect(vets.verificationRuns, ['v1']);
    expect(find.text('Verificación automática ejecutada'), findsOneWidget);
    expect(find.byKey(const Key('verification-rules')), findsOneWidget);
    expect(checked(tester, 'university'), isTrue);
  });

  testWidgets('si la verificación falla, el flujo manual sigue funcionando', (
    tester,
  ) async {
    await openReview(tester);
    vets.nextFailure = const VetFailure(
      'La verificación automática no está disponible. '
      'Sigue con la revisión manual.',
    );
    await tap(tester, 'run-verification');
    expect(find.byKey(const Key('snack-error')), findsOneWidget);
    expect(find.byKey(const Key('verification-empty')), findsOneWidget);

    await tap(tester, 'check-name');
    await tap(tester, 'check-university');
    await tap(tester, 'check-code');
    expect(approve(tester).onPressed, isNotNull);
    await tap(tester, 'review-approve');
    expect(vets.reviews.single.$2, isTrue);
    expect(vets.reviews.single.$4, isNot(contains('Verificación automática')));
  });
}
