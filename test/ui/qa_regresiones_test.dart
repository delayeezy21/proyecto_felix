// Regresiones de UI de los defectos del QA de la versión c251867
// (docs/qa/QA-c251867.md). Los defectos abiertos quedan con `skip`: al
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
    skip: true, // QA-12 abierto: quitar al corregir.
  );
}
