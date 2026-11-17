import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import '../helpers/fakes.dart';

/// Verifica que las pantallas no desborden (RenderFlex overflow) en un
/// teléfono angosto con texto grande, ni en escritorio, en tema claro y
/// oscuro. Un desborde lanza una excepción y hace fallar el test.
void main() {
  const phone = Size(360, 740);
  const desktop = Size(1280, 800);

  Future<void> pumpAt(
    WidgetTester tester,
    Widget app, {
    required Size size,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    tester.platformDispatcher
      ..textScaleFactorTestValue = textScale
      ..platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  /// Desplaza hasta el final de cada lista para construir todo el contenido.
  Future<void> scrollToEnd(WidgetTester tester) async {
    final scrollables = find.byType(Scrollable);
    for (var i = 0; i < scrollables.evaluate().length; i++) {
      final state = tester.state<ScrollableState>(scrollables.at(i));
      final position = state.position;
      if (position.axis != Axis.vertical) continue;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
    }
  }

  final variants = <(String, Size, double, Brightness)>[
    ('teléfono, texto 1.5x', phone, 1.5, Brightness.light),
    ('teléfono oscuro, texto 1.3x', phone, 1.3, Brightness.dark),
    ('escritorio', desktop, 1, Brightness.light),
  ];

  for (final (label, size, scale, brightness) in variants) {
    group(label, () {
      testWidgets('login y registro', (tester) async {
        final auth = FakeAuthRepository();
        final profiles = FakeProfileRepository(auth);
        await pumpAt(
          tester,
          testApp(auth: auth, profiles: profiles),
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        expect(find.byKey(const Key('login-submit')), findsOneWidget);
        // Con errores de validación visibles.
        await tester.ensureVisible(find.byKey(const Key('login-submit')));
        await tester.tap(find.byKey(const Key('login-submit')));
        await tester.pumpAndSettle();
        await scrollToEnd(tester);

        await tester.ensureVisible(find.byKey(const Key('login-go-signup')));
        await tester.tap(find.byKey(const Key('login-go-signup')));
        await tester.pumpAndSettle();
        await scrollToEnd(tester);
        expect(find.byKey(const Key('signup-submit')), findsOneWidget);
      });

      testWidgets('onboarding de dueño y de vet', (tester) async {
        final auth = FakeAuthRepository(userId: 'nuevo');
        final profiles = FakeProfileRepository(auth);
        await pumpAt(
          tester,
          testApp(auth: auth, profiles: profiles),
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        await scrollToEnd(tester);
        expect(find.byKey(const Key('onboarding-submit')), findsOneWidget);

        final vetSegment = find.text('Soy veterinario');
        await tester.ensureVisible(vetSegment);
        await tester.tap(vetSegment);
        await tester.pumpAndSettle();
        await scrollToEnd(tester);
      });

      testWidgets('inicio del dueño', (tester) async {
        final auth = FakeAuthRepository(userId: 'u1');
        final profiles = FakeProfileRepository(
          auth,
          accounts: {
            'u1': const Account(
              role: AppRole.owner,
              displayName: 'Ana María de los Ángeles',
            ),
          },
        );
        await pumpAt(
          tester,
          testApp(auth: auth, profiles: profiles),
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        expect(find.text('Inicio'), findsOneWidget);
      });

      testWidgets('perfil del vet pendiente', (tester) async {
        final auth = FakeAuthRepository(userId: 'v1');
        final profiles = FakeProfileRepository(
          auth,
          accounts: {
            'v1': const Account(
              role: AppRole.vet,
              displayName: 'Dra. Vera',
              vetStatus: VetStatus.pending,
            ),
          },
        );
        await pumpAt(
          tester,
          testApp(auth: auth, profiles: profiles, vets: FakeVetRepository()),
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        await scrollToEnd(tester);
        expect(find.byKey(const Key('vet-submit')), findsOneWidget);
      });

      testWidgets('panel del admin y revisión de un vet', (tester) async {
        final auth = FakeAuthRepository(userId: 'admin');
        final profiles = FakeProfileRepository(
          auth,
          accounts: {
            'admin': const Account(role: AppRole.admin, displayName: 'admin'),
          },
        );
        final vets =
            FakeVetRepository(
                profile: VetProfile(
                  userId: 'v1',
                  displayName: 'Dra. Vera',
                  status: VetStatus.pending,
                  university: 'Universidad de Chile',
                  graduationYear: 2015,
                  titleVerificationCode: 'ABC-123',
                  declarationAcceptedAt: DateTime(2026, 11, 16),
                  submittedAt: DateTime(2026, 11, 16),
                ),
              )
              ..pending = [
                VetApplicationSummary(
                  userId: 'v1',
                  displayName: 'Dra. Vera',
                  university: 'Universidad de Chile',
                  submittedAt: DateTime(2026, 11, 16),
                ),
              ];
        await pumpAt(
          tester,
          testApp(auth: auth, profiles: profiles, vets: vets),
          size: size,
          textScale: scale,
          brightness: brightness,
        );

        for (final tab in [
          'Especies',
          'Especialidades',
          'Tarifas',
          'Parámetros',
          'Clínicas 24 h',
          'Veterinarios',
        ]) {
          final tabFinder = find.widgetWithText(Tab, tab);
          await tester.ensureVisible(tabFinder);
          await tester.tap(tabFinder);
          await tester.pumpAndSettle();
        }

        await tester.tap(find.byKey(const Key('application-v1')));
        await tester.pumpAndSettle();
        await scrollToEnd(tester);
        expect(find.byKey(const Key('review-approve')), findsOneWidget);
      });
    });
  }
}
