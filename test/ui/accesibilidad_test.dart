// QA e578d72: accesibilidad básica de las pantallas rediseñadas, en un
// teléfono de 360 px y en tema claro y oscuro (docs/qa/QA-e578d72.md).
//
// Usa las guías de Flutter:
// * androidTapTargetGuideline: objetivos táctiles de al menos 48 × 48.
// * labeledTapTargetGuideline: todo lo tocable tiene una etiqueta semántica.
// * textContrastGuideline: contraste AA del texto (SPEC §6.6).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import '../helpers/fakes.dart';

void main() {
  /// 360 px de ancho y 3000 de alto: todo el contenido queda visible sin
  /// desplazar (las guías no consideran los nodos recortados por un scroll y
  /// darían falsos positivos).
  Future<void> pumpPhone(
    WidgetTester tester,
    Widget app, {
    Brightness brightness = Brightness.light,
  }) async {
    tester.view
      ..physicalSize = const Size(360, 3000)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  Future<void> expectAccessible(WidgetTester tester) async {
    final handle = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  }

  for (final brightness in Brightness.values) {
    group('360 px, tema ${brightness.name}', () {
      testWidgets('login', (tester) async {
        final auth = FakeAuthRepository();
        await pumpPhone(
          tester,
          testApp(auth: auth, profiles: FakeProfileRepository(auth)),
          brightness: brightness,
        );
        await expectAccessible(tester);
      });

      testWidgets('registro', (tester) async {
        final auth = FakeAuthRepository();
        await pumpPhone(
          tester,
          testApp(auth: auth, profiles: FakeProfileRepository(auth)),
          brightness: brightness,
        );
        await tester.ensureVisible(find.byKey(const Key('login-go-signup')));
        await tester.tap(find.byKey(const Key('login-go-signup')));
        await tester.pumpAndSettle();
        await expectAccessible(tester);
      });

      testWidgets('onboarding', (tester) async {
        final auth = FakeAuthRepository(userId: 'nuevo');
        await pumpPhone(
          tester,
          testApp(auth: auth, profiles: FakeProfileRepository(auth)),
          brightness: brightness,
        );
        await expectAccessible(tester);
      });

      testWidgets('perfil del vet (borrador)', (tester) async {
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
        await pumpPhone(
          tester,
          testApp(auth: auth, profiles: profiles, vets: FakeVetRepository()),
          brightness: brightness,
        );
        await expectAccessible(tester);
      });

      testWidgets('revisión de un vet (admin)', (tester) async {
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
        await pumpPhone(
          tester,
          testApp(auth: auth, profiles: profiles, vets: vets),
          brightness: brightness,
        );
        await expectAccessible(tester);
        final tab = find.widgetWithText(Tab, 'Veterinarios');
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('application-v1')));
        await tester.pumpAndSettle();
        await expectAccessible(tester);
      });
    });
  }

  testWidgets('QA-18 (regresión de QA-08): las notas de revisión tienen '
      'límite de 500 caracteres', (tester) async {
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
    tester.view
      ..physicalSize = const Size(1000, 3000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, vets: vets),
    );
    await tester.pumpAndSettle();
    final tab = find.widgetWithText(Tab, 'Veterinarios');
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('application-v1')));
    await tester.pumpAndSettle();
    final notes = tester.widget<TextField>(
      find.byKey(const Key('review-notes')),
    );
    expect(
      notes.maxLength,
      500,
      reason: 'checklist (~250) + notas debe caber en review_notes (≤ 1000)',
    );
  });
}
