import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;

  setUp(() {
    auth = FakeAuthRepository(userId: 'nuevo');
    profiles = FakeProfileRepository(auth);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 2000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(testApp(auth: auth, profiles: profiles));
    await tester.pumpAndSettle();
  }

  testWidgets('no continúa sin aceptar los términos', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('onboarding-name')), 'Ana');
    await tester.enterText(
      find.byKey(const Key('onboarding-phone')),
      '+56 9 1234 5678',
    );
    await tester.ensureVisible(find.byKey(const Key('onboarding-submit')));
    await tester.tap(find.byKey(const Key('onboarding-submit')));
    await tester.pump();
    expect(find.byKey(const Key('onboarding-terms-error')), findsOneWidget);
    expect(profiles.registrationCalls, isEmpty);
  });

  testWidgets('registra al dueño con las versiones vigentes y abre su inicio', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('onboarding-name')), 'Ana');
    await tester.enterText(
      find.byKey(const Key('onboarding-phone')),
      '+56 9 1234 5678',
    );
    await tester.ensureVisible(find.byKey(const Key('onboarding-terms')));
    await tester.tap(find.byKey(const Key('onboarding-terms')));
    await tester.ensureVisible(find.byKey(const Key('onboarding-submit')));
    await tester.tap(find.byKey(const Key('onboarding-submit')));
    await tester.pumpAndSettle();

    final call = profiles.registrationCalls.single;
    expect(call.role, AppRole.owner);
    expect(call.displayName, 'Ana');
    expect(call.phone, '+56 9 1234 5678');
    expect(call.legal.terms, legalTest.terms);
    expect(call.legal.privacy, legalTest.privacy);
    expect(call.marketing, isFalse, reason: 'el consentimiento es opcional');
    expect(find.text('Hola, Ana'), findsOneWidget);
  });

  testWidgets('el vet no ingresa teléfono y queda en revisión', (tester) async {
    await open(tester);
    await tester.tap(find.text('Soy veterinario'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding-phone')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('onboarding-name')),
      'Dra. Vera',
    );
    await tester.ensureVisible(find.byKey(const Key('onboarding-terms')));
    await tester.tap(find.byKey(const Key('onboarding-terms')));
    await tester.ensureVisible(find.byKey(const Key('onboarding-submit')));
    await tester.tap(find.byKey(const Key('onboarding-submit')));
    await tester.pumpAndSettle();

    final call = profiles.registrationCalls.single;
    expect(call.role, AppRole.vet);
    expect(call.phone, isNull);
    expect(find.text('Cuenta en revisión'), findsOneWidget);
  });

  testWidgets('muestra el error del backend', (tester) async {
    profiles.nextFailure = const ProfileFailure(
      'Tu cuenta ya completó el registro.',
    );
    await open(tester);
    await tester.enterText(find.byKey(const Key('onboarding-name')), 'Ana');
    await tester.enterText(
      find.byKey(const Key('onboarding-phone')),
      '+56 9 1234 5678',
    );
    await tester.ensureVisible(find.byKey(const Key('onboarding-terms')));
    await tester.tap(find.byKey(const Key('onboarding-terms')));
    await tester.ensureVisible(find.byKey(const Key('onboarding-submit')));
    await tester.tap(find.byKey(const Key('onboarding-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Tu cuenta ya completó el registro.'), findsOneWidget);
  });
}
