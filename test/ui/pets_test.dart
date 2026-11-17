import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/owner_repositories.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/pet.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakePetRepository pets;

  setUp(() {
    auth = FakeAuthRepository(userId: 'o1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {'o1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
    pets = FakePetRepository();
  });

  Future<void> pumpOwner(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, pets: pets),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, Key field, String option) async {
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('sin mascotas muestra el estado vacío y el botón agregar', (
    tester,
  ) async {
    await pumpOwner(tester);
    expect(find.text('Hola, Ana'), findsOneWidget);
    expect(find.text('Aún no registras mascotas.'), findsOneWidget);
    expect(find.byKey(const Key('pet-add')), findsOneWidget);
  });

  testWidgets('al elegir la especie, las razas se filtran (HU1.2)', (
    tester,
  ) async {
    await pumpOwner(tester);
    await tester.tap(find.byKey(const Key('pet-add')));
    await tester.pumpAndSettle();

    await pick(tester, const Key('pet-species'), 'Perro');
    await tester.tap(find.byKey(const Key('pet-breed-1')));
    await tester.pumpAndSettle();
    expect(find.text('Beagle'), findsWidgets);
    expect(find.text('Siamés'), findsNothing);
    await tester.tap(find.text('Beagle').last);
    await tester.pumpAndSettle();

    // Cambiar de especie reinicia la raza y muestra las de la nueva especie.
    await pick(tester, const Key('pet-species'), 'Gato');
    expect(find.text('Beagle'), findsNothing);
    await tester.tap(find.byKey(const Key('pet-breed-2')));
    await tester.pumpAndSettle();
    expect(find.text('Siamés'), findsWidgets);
    expect(find.text('Mestizo'), findsNothing);
  });

  testWidgets('registra una mascota con todos sus datos', (tester) async {
    await pumpOwner(tester);
    await tester.tap(find.byKey(const Key('pet-add')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pet-name')), 'Firulais');
    await pick(tester, const Key('pet-species'), 'Perro');
    await pick(tester, const Key('pet-breed-1'), 'Beagle');
    await tester.tap(find.text('Macho'));
    await pick(tester, const Key('pet-birth-year'), '2020');
    await pick(tester, const Key('pet-birth-month-2020'), 'Marzo');
    await tester.tap(find.byKey(const Key('pet-sterilized')));
    await tester.enterText(
      find.byKey(const Key('pet-microchip')),
      '152000000000001',
    );
    await tester.tap(find.byKey(const Key('pet-save')));
    await tester.pumpAndSettle();

    final d = pets.created.single;
    expect(d.name, 'Firulais');
    expect(d.speciesId, 1);
    expect(d.breedId, 11);
    expect(d.sex, PetSex.male);
    expect(d.birthDateApprox, DateTime(2020, 3));
    expect(d.sterilized, isTrue);
    expect(d.toRow()['microchip'], '152000000000001');
    expect(d.toRow()['birth_date_approx'], '2020-03-01');
    expect(find.text('Firulais'), findsOneWidget);
  });

  testWidgets('valida nombre, especie y microchip', (tester) async {
    await pumpOwner(tester);
    await tester.tap(find.byKey(const Key('pet-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pet-microchip')), '12345');
    await tester.tap(find.byKey(const Key('pet-save')));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el nombre'), findsOneWidget);
    expect(find.text('Elige la especie'), findsOneWidget);
    expect(find.text('El microchip tiene 15 dígitos.'), findsOneWidget);
    expect(pets.created, isEmpty);
  });

  testWidgets('muestra el error del servidor sin perder el formulario', (
    tester,
  ) async {
    pets.nextFailure = const OwnerDataFailure(
      'Puedes tener hasta 20 mascotas activas',
    );
    await pumpOwner(tester);
    await tester.tap(find.byKey(const Key('pet-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pet-name')), 'Michi');
    await pick(tester, const Key('pet-species'), 'Gato');
    await tester.tap(find.byKey(const Key('pet-save')));
    await tester.pumpAndSettle();
    expect(find.text('Puedes tener hasta 20 mascotas activas'), findsOneWidget);
    expect(find.text('Michi'), findsOneWidget);
  });

  testWidgets('edita y desactiva una mascota (no se borra)', (tester) async {
    pets.pets.add(
      Pet(
        id: 'p1',
        name: 'Pelusa',
        speciesId: 2,
        speciesName: 'Gato',
        sex: PetSex.female,
        sterilized: false,
        active: true,
        birthDateApprox: DateTime(2022, 5),
      ),
    );
    await pumpOwner(tester);
    expect(find.textContaining('Gato · Hembra'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pet-p1')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pet-name')), 'Pelusita');
    await tester.tap(find.byKey(const Key('pet-save')));
    await tester.pumpAndSettle();
    expect(pets.updated.single.$1, 'p1');
    expect(pets.updated.single.$2.name, 'Pelusita');
    expect(pets.updated.single.$2.birthDateApprox, DateTime(2022, 5));

    await tester.tap(find.byKey(const Key('pet-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pet-toggle-active')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pet-deactivate-confirm')));
    await tester.pumpAndSettle();
    expect(pets.pets.single.active, isFalse);
    expect(find.textContaining('Desactivada'), findsOneWidget);
  });

  testWidgets('una mascota de especie desactivada se sigue mostrando', (
    tester,
  ) async {
    pets.pets.add(
      const Pet(
        id: 'p9',
        name: 'Escamas',
        speciesId: 99,
        sex: PetSex.unknown,
        sterilized: false,
        active: true,
      ),
    );
    await pumpOwner(tester);
    expect(find.textContaining('Especie no disponible'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pet-p9')));
    await tester.pumpAndSettle();
    expect(find.text('Escamas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
