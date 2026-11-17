import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/pricing_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/ui/features/owner/views/quote_breakdown.dart';

import '../helpers/fakes.dart';

String _text(WidgetTester tester, Key key) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(key),
        matching: find.byType(Text),
        matchRoot: true,
      ),
    )
    .map((t) => t.data)
    .join(' ');

void main() {
  Future<void> pumpBreakdown(WidgetTester tester, Quote quote) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: QuoteBreakdown(quote: quote)),
        ),
      ),
    );
  }

  group('desglose del precio (widget)', () {
    testWidgets(r'ejemplo del SPEC: $30.000 → vet $25.500', (tester) async {
      await pumpBreakdown(tester, sampleQuote());
      expect(_text(tester, const Key('quote-base')), contains(r'$30.000'));
      expect(_text(tester, const Key('quote-total')), contains(r'$30.000'));
      expect(_text(tester, const Key('quote-vet')), contains(r'$25.500'));
      // Comisión de Felix neta = 4.500 − 900.
      expect(_text(tester, const Key('quote-platform')), contains(r'$3.600'));
      expect(_text(tester, const Key('quote-foundation')), contains(r'$900'));
      expect(find.byKey(const Key('quote-urgent')), findsNothing);
      expect(find.byKey(const Key('quote-donation')), findsNothing);
      expect(find.byKey(const Key('quote-distance-pending')), findsOneWidget);
      expect(find.textContaining('Pago simulado'), findsOneWidget);
    });

    testWidgets('urgencia, distancia, descuento y donación', (tester) async {
      await pumpBreakdown(
        tester,
        sampleQuote(
          mode: VisitMode.urgent,
          urgent: 9000,
          billableKm: 3,
          distance: 1500,
          discount: 3000,
          fee: 5625,
          share: 1125,
          donation: 2000,
          distanceKm: 8,
        ),
      );
      expect(_text(tester, const Key('quote-urgent')), contains(r'$9.000'));
      final distance = _text(tester, const Key('quote-distance'));
      expect(distance, contains('3 km'));
      expect(distance, contains(r'$1.500'));
      expect(_text(tester, const Key('quote-discount')), contains(r'-$3.000'));
      // Servicio 30.000 − 3.000 + 9.000 + 1.500 = 37.500 (+ 2.000 donación).
      expect(_text(tester, const Key('quote-service')), contains(r'$37.500'));
      expect(_text(tester, const Key('quote-donation')), contains(r'$2.000'));
      expect(_text(tester, const Key('quote-total')), contains(r'$39.500'));
      // A la fundación: 1.125 de la comisión + 2.000 de donación.
      expect(_text(tester, const Key('quote-foundation')), contains(r'$3.125'));
    });

    testWidgets(r'consulta general $26.990 hasta 5 km → vet $22.941', (
      tester,
    ) async {
      // Montos tal como los devuelve quote_visit con la tarifa vigente.
      await pumpBreakdown(
        tester,
        sampleQuote(base: 26990, fee: 4049, share: 810, distanceKm: 4.5),
      );
      expect(_text(tester, const Key('quote-total')), contains(r'$26.990'));
      expect(_text(tester, const Key('quote-vet')), contains(r'$22.941'));
      expect(_text(tester, const Key('quote-platform')), contains(r'$3.239'));
      expect(_text(tester, const Key('quote-foundation')), contains(r'$810'));
      expect(
        _text(tester, const Key('quote-distance')),
        contains('4,5 km, sin recargo'),
      );
    });

    testWidgets('distancia dentro de los km incluidos', (tester) async {
      await pumpBreakdown(tester, sampleQuote(distanceKm: 3.5));
      expect(
        _text(tester, const Key('quote-distance')),
        contains('3,5 km, sin recargo'),
      );
    });
  });

  group('cotizar (dueño)', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeQuoteRepository quotes;
    late FakeFoundationRepository foundations;
    late FakePetRepository pets;
    late FakeAddressRepository addresses;

    setUp(() {
      auth = FakeAuthRepository(userId: 'o1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'o1': const Account(role: AppRole.owner, displayName: 'Ana'),
        },
      );
      quotes = FakeQuoteRepository();
      foundations = FakeFoundationRepository();
      pets = FakePetRepository(
        pets: [
          const Pet(
            id: 'p1',
            name: 'Firulais',
            speciesId: 1,
            speciesName: 'Perro',
            sex: PetSex.male,
            sterilized: true,
            active: true,
          ),
        ],
      );
      addresses = FakeAddressRepository(
        addresses: [
          const Address(
            id: 'a1',
            label: 'Casa',
            streetText: 'Av. Ficticia 123',
            communeId: 102,
            communeName: 'Ñuñoa',
            point: GeoPoint(-33.4569, -70.5974),
            active: true,
          ),
        ],
      );
    });

    Future<void> openQuote(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(800, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          pets: pets,
          addresses: addresses,
          quotes: quotes,
          foundations: foundations,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Cotizar'));
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, Key field, String option) async {
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    Future<void> fill(WidgetTester tester) async {
      await pick(tester, const Key('quote-pet'), 'Firulais · Perro');
      await pick(tester, const Key('quote-address'), 'Casa · Ñuñoa');
      await pick(tester, const Key('quote-specialty'), 'Medicina general');
    }

    testWidgets('valida el formulario antes de cotizar', (tester) async {
      await openQuote(tester);
      await tester.tap(find.byKey(const Key('quote-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Elige la mascota'), findsOneWidget);
      expect(quotes.requests, isEmpty);
    });

    testWidgets('cotiza y muestra el desglose del servidor', (tester) async {
      quotes.respond = (r) => sampleQuote(
        mode: r.mode,
        urgent: r.mode == VisitMode.urgent ? 9000 : 0,
        fee: 5850,
        share: 1170,
        donation: r.extraDonation,
      );
      await openQuote(tester);
      await fill(tester);
      await tester.tap(find.text('Urgencia'));
      await tester.pumpAndSettle();
      await pick(
        tester,
        const Key('quote-foundation'),
        'Fundación Demo Bigotes',
      );
      await tester.enterText(
        find.byKey(const Key('quote-donation-field')),
        '2.000',
      );
      await tester.tap(find.byKey(const Key('quote-submit')));
      await tester.pumpAndSettle();

      final r = quotes.requests.single;
      expect(r.petId, 'p1');
      expect(r.addressId, 'a1');
      expect(r.specialtyId, 1);
      expect(r.mode, VisitMode.urgent);
      expect(r.foundationId, 'f2');
      expect(r.extraDonation, 2000);
      expect(find.byKey(const Key('quote-breakdown')), findsOneWidget);
      // 30.000 + 9.000 + 2.000 de donación.
      expect(_text(tester, const Key('quote-total')), contains(r'$41.000'));

      // Cambiar un dato invalida la cotización mostrada.
      await tester.tap(find.text('Agendada'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quote-breakdown')), findsNothing);
    });

    testWidgets('usa la fundación elegida en el perfil', (tester) async {
      foundations.myChoice = 'f2';
      await openQuote(tester);
      await fill(tester);
      await tester.tap(find.byKey(const Key('quote-submit')));
      await tester.pumpAndSettle();
      expect(quotes.requests.single.foundationId, 'f2');
    });

    testWidgets('muestra el error del servidor', (tester) async {
      quotes.nextFailure = const PricingFailure(
        'La especialidad no atiende a esta especie',
      );
      await openQuote(tester);
      await fill(tester);
      await tester.tap(find.byKey(const Key('quote-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('La especialidad no atiende a esta especie'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('quote-breakdown')), findsNothing);
    });

    testWidgets('sin mascotas ni direcciones pide agregarlas', (tester) async {
      pets.pets.clear();
      await openQuote(tester);
      expect(find.byKey(const Key('quote-missing-data')), findsOneWidget);
    });

    testWidgets('elige su fundación en el perfil', (tester) async {
      await openQuote(tester);
      await tester.tap(find.byKey(const Key('owner-profile')));
      await tester.pumpAndSettle();
      expect(find.text('Fundación que apoyas'), findsOneWidget);
      expect(find.textContaining('nunca tu nombre'), findsOneWidget);
      await pick(
        tester,
        const Key('profile-foundation'),
        'Fundación Demo Bigotes',
      );
      await tester.tap(find.byKey(const Key('profile-foundation-save')));
      await tester.pumpAndSettle();
      expect(foundations.choices, ['f2']);
      expect(find.text('Fundación guardada'), findsOneWidget);
    });
  });

  group('panel de la fundación', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeFoundationRepository foundations;

    setUp(() {
      auth = FakeAuthRepository(userId: 'f');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'f': const Account(
            role: AppRole.foundation,
            displayName: 'fund@test.local',
          ),
        },
      );
      foundations = FakeFoundationRepository()
        ..member = const Foundation(
          id: 'f1',
          name: 'Fundación Demo Patitas',
          active: true,
          isDefault: true,
        );
    });

    Future<void> open(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(800, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(auth: auth, profiles: profiles, foundations: foundations),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('muestra el total y el detalle por mes', (tester) async {
      foundations.months = [
        FoundationMonth(
          month: DateTime(2026, 11),
          commissionTotal: 1770,
          donationTotal: 1000,
          total: 2770,
        ),
        FoundationMonth(
          month: DateTime(2026, 10),
          commissionTotal: 900,
          donationTotal: 0,
          total: 900,
        ),
      ];
      await open(tester);
      expect(find.text('Fundación Demo Patitas'), findsOneWidget);
      expect(_text(tester, const Key('foundation-total')), r'$3.670');
      expect(find.text('Noviembre 2026'), findsOneWidget);
      expect(find.text('Octubre 2026'), findsOneWidget);
      expect(find.textContaining(r'Comisiones: $2.670'), findsOneWidget);
      expect(find.textContaining('no comparte nombres'), findsOneWidget);
    });

    testWidgets('sin aportes muestra el estado vacío', (tester) async {
      await open(tester);
      expect(find.byKey(const Key('foundation-empty')), findsOneWidget);
      expect(_text(tester, const Key('foundation-total')), r'$0');
    });

    testWidgets('sin membresía activa lo indica', (tester) async {
      foundations.member = null;
      await open(tester);
      expect(find.byKey(const Key('foundation-no-membership')), findsOneWidget);
    });
  });

  group('fundaciones (admin)', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeFoundationRepository foundations;

    setUp(() {
      auth = FakeAuthRepository(userId: 'admin');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'admin': const Account(role: AppRole.admin, displayName: 'admin'),
        },
      );
      foundations = FakeFoundationRepository();
    });

    Future<void> open(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(1200, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(auth: auth, profiles: profiles, foundations: foundations),
      );
      await tester.pumpAndSettle();
      final tab = find.widgetWithText(Tab, 'Fundaciones');
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await tester.pumpAndSettle();
    }

    testWidgets('agrega una fundación y la marca por defecto', (tester) async {
      await open(tester);
      expect(find.text('Fundación Demo Patitas'), findsOneWidget);

      await tester.tap(find.byKey(const Key('add-foundation')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('foundation-name')),
        'Fundación Demo Huellas',
      );
      await tester.enterText(
        find.byKey(const Key('foundation-website')),
        'http://sin-tls',
      );
      await tester.tap(find.byKey(const Key('foundation-save')));
      await tester.pumpAndSettle();
      expect(find.text('Debe comenzar con https://'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('foundation-website')), '');
      await tester.tap(find.byKey(const Key('foundation-save')));
      await tester.pumpAndSettle();
      expect(foundations.created.single.name, 'Fundación Demo Huellas');
      expect(find.text('Fundación Demo Huellas'), findsOneWidget);

      await tester.tap(find.byKey(const Key('default-f3')));
      await tester.pumpAndSettle();
      expect(foundations.list.firstWhere((f) => f.isDefault).id, 'f3');
    });

    testWidgets('la fundación por defecto no se puede desactivar', (
      tester,
    ) async {
      await open(tester);
      final defaultSwitch = tester.widget<Switch>(
        find.byKey(const Key('active-f1')),
      );
      expect(defaultSwitch.onChanged, isNull);
      await tester.tap(find.byKey(const Key('active-f2')));
      await tester.pumpAndSettle();
      expect(foundations.list.firstWhere((f) => f.id == 'f2').active, isFalse);
    });
  });
}
