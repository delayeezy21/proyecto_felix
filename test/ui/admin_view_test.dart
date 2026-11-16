import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeCatalogRepository catalog;

  setUp(() {
    auth = FakeAuthRepository(userId: 'admin');
    profiles = FakeProfileRepository(
      auth,
      accounts: {
        'admin': const Account(role: AppRole.admin, displayName: 'admin'),
      },
    );
    catalog = FakeCatalogRepository();
  });

  Future<void> open(WidgetTester tester, {String? tab}) async {
    tester.view
      ..physicalSize = const Size(1000, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, catalog: catalog),
    );
    await tester.pumpAndSettle();
    if (tab != null) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('el admin llega a su panel con los catálogos', (tester) async {
    await open(tester);
    expect(find.text('Administración'), findsOneWidget);
    expect(find.text('Perro'), findsOneWidget);
    expect(find.text('Gato'), findsOneWidget);
  });

  testWidgets('agrega una especie con slug generado', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('add-species')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dialog-field')), 'Hurón');
    await tester.tap(find.byKey(const Key('dialog-save')));
    await tester.pumpAndSettle();
    expect(find.text('Hurón'), findsOneWidget);
    expect(catalog.itemsByKind[CatalogKind.species]!.last.slug, 'huron');
  });

  testWidgets('desactiva una especie con el interruptor', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('active-gato')));
    await tester.pumpAndSettle();
    expect(
      catalog.itemsByKind[CatalogKind.species]!
          .firstWhere((e) => e.slug == 'gato')
          .active,
      isFalse,
    );
    expect(find.text('Inactiva'), findsOneWidget);
  });

  testWidgets('muestra el error del backend al crear', (tester) async {
    catalog.nextFailure = const CatalogFailure(
      'Ya existe un registro con ese nombre.',
    );
    await open(tester);
    await tester.tap(find.byKey(const Key('add-species')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dialog-field')), 'Perro');
    await tester.tap(find.byKey(const Key('dialog-save')));
    await tester.pumpAndSettle();
    expect(find.text('Ya existe un registro con ese nombre.'), findsOneWidget);
  });

  testWidgets('edita una tarifa y valida el monto', (tester) async {
    await open(tester, tab: 'Tarifas');
    expect(find.text(r'$25.000'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tariff-1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dialog-field')), '0');
    await tester.tap(find.byKey(const Key('dialog-save')));
    await tester.pump();
    expect(find.text('Ingresa un monto mayor a 0'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dialog-field')), '28000');
    await tester.tap(find.byKey(const Key('dialog-save')));
    await tester.pumpAndSettle();
    expect(catalog.tariffList.single.basePrice, 28000);
    expect(find.text(r'$28.000'), findsOneWidget);
  });

  testWidgets('crea una nueva versión de parámetros tras confirmar', (
    tester,
  ) async {
    await open(tester, tab: 'Parámetros');
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('pricing-commission')))
          .controller!
          .text,
      '15',
    );

    await tester.enterText(find.byKey(const Key('pricing-commission')), '120');
    await tester.tap(find.byKey(const Key('pricing-save')));
    await tester.pump();
    expect(find.text('Entre 0 y 100'), findsOneWidget);
    expect(catalog.pricingVersions, isEmpty);

    await tester.enterText(find.byKey(const Key('pricing-commission')), '12');
    await tester.tap(find.byKey(const Key('pricing-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pricing-confirm')));
    await tester.pumpAndSettle();
    expect(catalog.pricingVersions.single.commissionPct, 12);
    expect(catalog.pricingVersions.single.foundationPct, 20);
  });

  testWidgets('agrega una clínica 24 h con región y comuna', (tester) async {
    await open(tester, tab: 'Clínicas 24 h');
    expect(find.text('Aún no hay clínicas registradas.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-clinic')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('clinic-name')), 'Clínica X');
    await tester.tap(find.byKey(const Key('clinic-region')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Valparaíso').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clinic-commune-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Viña del Mar').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('clinic-address')), 'Calle 1');
    await tester.enterText(
      find.byKey(const Key('clinic-phone')),
      '+56 32 200 0000',
    );
    await tester.tap(find.byKey(const Key('clinic-save')));
    await tester.pumpAndSettle();

    expect(catalog.clinicList.single.communeId, 201);
    expect(find.text('Clínica X'), findsOneWidget);
  });
}
