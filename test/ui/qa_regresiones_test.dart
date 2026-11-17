// Regresiones de UI de los defectos encontrados por el QA (docs/qa/QA-c251867.md
// y docs/qa/QA-d0c586c.md). Los defectos abiertos quedan con `skip`: al
// corregirlos, quita el `skip` para que la prueba quede activa.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeVetRepository vets;

  setUp(() {
    auth = FakeAuthRepository(userId: 'v1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {
        'v1': const Account(
          role: AppRole.vet,
          displayName: 'Dra. Vera',
          vetStatus: VetStatus.pending,
        ),
      },
    );
    vets = FakeVetRepository(
      profile: VetProfile(
        userId: 'v1',
        displayName: 'Dra. Vera',
        status: VetStatus.pending,
        university: 'Universidad de Chile',
        graduationYear: 2015,
        declarationAcceptedAt: DateTime(2026, 11, 10),
        submittedAt: DateTime(2026, 11, 10),
      ),
    );
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, vets: vets),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('en revisión, los datos profesionales se muestran bloqueados', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('En revisión'), findsOneWidget);
    expect(find.byKey(const Key('vet-university')), findsNothing);
    expect(find.byKey(const Key('vet-submit')), findsNothing);
  });

  testWidgets(
    'QA-12: en revisión, las especies y especialidades enviadas no se '
    'cambian desde la UI',
    (tester) async {
      await open(tester);
      final chip = tester.widget<FilterChip>(
        find.byKey(const Key('chip-species-perro')),
      );
      expect(
        chip.onSelected,
        isNull,
        reason: 'la solicitud está en revisión: el admin revisa lo enviado',
      );
    },
  );

  // --- QA de la versión d0c586c (docs/qa/QA-d0c586c.md) ---------------------

  group('QA-15: el aviso "Guardando…" no queda pegado', () {
    setUp(() {
      vets.profile = const VetProfile(
        userId: 'v1',
        displayName: 'Dra. Vera',
        status: VetStatus.pending,
        university: 'Universidad de Chile',
        graduationYear: 2015,
      );
    });

    testWidgets('si el vet escribe y deshace antes del autoguardado', (
      tester,
    ) async {
      await open(tester);
      final field = find.byKey(const Key('vet-university'));
      await tester.enterText(field, 'Universidad de Chilex');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(field, 'Universidad de Chile');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('vet-saving-before-submit')),
        findsNothing,
        reason: 'no hay nada que guardar: el envío no debe quedar bloqueado',
      );
    }, skip: true); // QA-15 abierto: quitar al corregir.

    testWidgets('si el dato queda inválido (no se autoguarda)', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const Key('vet-year')), '19');
      await tester.pump(const Duration(seconds: 2));
      await tester.enterText(find.byKey(const Key('vet-year')), '2015');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vet-saving-before-submit')), findsNothing);
    }, skip: true); // QA-15 abierto: quitar al corregir.
  });
}
