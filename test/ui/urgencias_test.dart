import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/services/live_location_service.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/features/urgent/view_models/urgent_providers.dart';

import '../helpers/fakes.dart';

/// Fase 8: urgencias en la app (dueño y vet) con repositorios falsos y reloj
/// manual (los refrescos y las cuentas regresivas se disparan a mano).
void main() {
  void view(WidgetTester tester, {double width = 800, double scale = 1}) {
    tester.view
      ..physicalSize = Size(width, 2600)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
  }

  late ManualClock clock;
  late FakeUrgentRepository urgent;
  late FakeVisitRepository visits;
  late FakeLiveLocationService live;

  setUp(() {
    clock = ManualClock();
    visits = FakeVisitRepository();
    urgent = FakeUrgentRepository()..visits = visits;
    live = FakeLiveLocationService();
  });

  group('dueño', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakePetRepository pets;
    late FakeAddressRepository addresses;
    late FakeCatalogRepository catalog;
    late FakeMapAdapter map;

    setUp(() {
      auth = FakeAuthRepository(userId: 'o1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'o1': const Account(role: AppRole.owner, displayName: 'Ana'),
        },
      );
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
      catalog = FakeCatalogRepository();
      map = FakeMapAdapter();
    });

    Future<void> openVisits(
      WidgetTester tester, {
      double width = 800,
      double scale = 1,
    }) async {
      view(tester, width: width, scale: scale);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          pets: pets,
          addresses: addresses,
          catalog: catalog,
          visits: visits,
          urgent: urgent,
          live: live,
          clock: clock,
          map: map,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Visitas'));
      await tester.pumpAndSettle();
    }

    Future<void> openVisit(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(Key('visit-$id')));
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, Key field, String option) async {
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    testWidgets('"Urgencia ahora" pide mascota y dirección y abre "Buscando '
        'vet"', (tester) async {
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-urgent')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('urgent-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Elige la mascota'), findsOneWidget);
      expect(find.text('Elige la dirección'), findsOneWidget);
      expect(urgent.requests, isEmpty);

      await pick(tester, const Key('urgent-pet'), 'Firulais · Perro');
      await pick(tester, const Key('urgent-address'), 'Casa · Ñuñoa');
      await tester.enterText(find.byKey(const Key('urgent-notes')), 'Vómitos');
      await tester.tap(find.byKey(const Key('urgent-submit')));
      await tester.pumpAndSettle();

      expect(urgent.requests.single, {
        'pet': 'p1',
        'address': 'a1',
        'specialty': null,
        'notes': 'Vómitos',
      });
      expect(find.byKey(const Key('urgent-searching')), findsOneWidget);
      expect(find.text('Buscando veterinario'), findsOneWidget);
      // Tope mientras no hay distancia.
      expect(find.byKey(const Key('quote-max-total')), findsOneWidget);
      expect(find.textContaining(r'hasta $43.087'), findsOneWidget);
    });

    testWidgets('"Buscando vet": radio, tanda, cuenta regresiva y refresco '
        'cada 5 s', (tester) async {
      visits.visits = [urgentOwnerVisit()];
      await openVisits(tester);
      await openVisit(tester, 'urg1');

      expect(find.text('Quedan 10:00 de búsqueda'), findsOneWidget);
      expect(find.text('Preparando la primera tanda…'), findsOneWidget);
      expect(urgent.statusCalls, ['urg1']);

      urgent.status = UrgentSearchStatus(
        visitId: 'urg1',
        status: VisitStatus.searching,
        searchUntil: DateTime(2026, 11, 24, 12, 10),
        radiusKm: 10,
        batches: 2,
        pendingOffers: 3,
      );
      clock
        ..fire(UrgentSearchController.poll)
        ..advance(const Duration(seconds: 65));
      await tester.pumpAndSettle();
      expect(urgent.statusCalls, hasLength(2));
      expect(find.text('Radio actual: 10 km'), findsOneWidget);
      expect(
        find.text('Tanda 2: 3 veterinarios revisando tu solicitud'),
        findsOneWidget,
      );
      expect(find.text('Quedan 8:55 de búsqueda'), findsOneWidget);
    });

    testWidgets('al ser aceptada muestra el detalle normal de la visita', (
      tester,
    ) async {
      visits.visits = [urgentOwnerVisit()];
      await openVisits(tester);
      await openVisit(tester, 'urg1');
      expect(find.byKey(const Key('urgent-searching')), findsOneWidget);

      visits.visits = [urgentOwnerVisit(status: VisitStatus.accepted)];
      urgent.status = UrgentSearchStatus(
        visitId: 'urg1',
        status: VisitStatus.accepted,
        searchUntil: DateTime(2026, 11, 24, 12, 10),
        radiusKm: 5,
        batches: 1,
        pendingOffers: 0,
      );
      clock.fire(UrgentSearchController.poll);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('urgent-searching')), findsNothing);
      expect(find.byKey(const Key('visit-status-accepted')), findsOneWidget);
      expect(find.text('Dra. Vera'), findsOneWidget);
    });

    testWidgets('cancelar mientras busca es gratis', (tester) async {
      visits.visits = [urgentOwnerVisit()];
      await openVisits(tester);
      await openVisit(tester, 'urg1');
      await tester.tap(find.byKey(const Key('urgent-cancel')));
      await tester.pumpAndSettle();
      expect(find.textContaining('sin costo'), findsWidgets);
      await tester.tap(find.byKey(const Key('reason-confirm')));
      await tester.pumpAndSettle();
      expect(visits.transitions.single.$2, VisitStatus.cancelledOwner);
      expect(find.text('Urgencia cancelada'), findsOneWidget);
    });

    testWidgets('no_vet_found muestra "Agendar primera hora libre" y '
        '"Clínicas 24 h" (SPEC HU2.1)', (tester) async {
      catalog.clinicList.addAll(const [
        EmergencyClinic(
          id: 'c1',
          name: 'Clínica Ficticia Centro',
          communeId: 101,
          communeName: 'Santiago',
          address: 'Calle Falsa 1',
          phone: '+56 2 2222 2222',
          active: true,
        ),
        EmergencyClinic(
          id: 'c2',
          name: 'Clínica Ficticia Oriente',
          communeId: 102,
          communeName: 'Ñuñoa',
          address: 'Calle Falsa 2',
          phone: '+56 2 3333 3333',
          active: true,
        ),
        EmergencyClinic(
          id: 'c3',
          name: 'Clínica Cerrada',
          communeId: 102,
          communeName: 'Ñuñoa',
          address: 'Calle Falsa 3',
          phone: '+56 2 4444 4444',
          active: false,
        ),
      ]);
      visits.visits = [urgentOwnerVisit(status: VisitStatus.noVetFound)];
      await openVisits(tester);
      await openVisit(tester, 'urg1');

      expect(find.byKey(const Key('no-vet-found')), findsOneWidget);
      expect(find.textContaining('No se hizo ningún cobro'), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Agendar primera hora libre'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Clínicas 24 h'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('visit-pay')), findsNothing);

      // Clínicas 24 h: solo activas, primero las de la comuna.
      await tester.tap(find.byKey(const Key('no-vet-clinics')));
      await tester.pumpAndSettle();
      final tiles = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => t.key)
          .toList();
      expect(tiles, [const Key('clinic-c2'), const Key('clinic-c1')]);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Agendar: flujo agendado con la mascota y la dirección elegidas.
      await tester.tap(find.byKey(const Key('no-vet-schedule')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-from-urgent')), findsOneWidget);
      expect(find.text('Firulais · Perro'), findsOneWidget);
      expect(find.text('Casa · Ñuñoa'), findsOneWidget);
    });

    testWidgets('en camino: el dueño ve al vet en el mapa y sale del canal '
        'al llegar', (tester) async {
      visits.visits = [urgentOwnerVisit(status: VisitStatus.enRoute)];
      await openVisits(tester);
      await openVisit(tester, 'urg1');
      expect(find.byKey(const Key('live-map')), findsOneWidget);
      expect(
        find.text('Esperando la ubicación del veterinario…'),
        findsOneWidget,
      );
      final session = live.last('urg1')!;
      session.controller.add(
        LivePosition(LiveLocation(const GeoPoint(-33.45, -70.6), clock.now())),
      );
      await tester.pumpAndSettle();
      expect(map.lastMarkers.single.point, const GeoPoint(-33.45, -70.6));
      expect(find.textContaining('Actualizada a las'), findsOneWidget);

      // Llega: el refresco de 15 s trae "llegó" y el mapa desaparece.
      visits.visits = [urgentOwnerVisit(status: VisitStatus.arrived)];
      clock.fire(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live-map')), findsNothing);
      expect(session.left, isTrue);
    });

    for (final status in [VisitStatus.searching, VisitStatus.noVetFound]) {
      testWidgets('${status.wire} sin desbordes a 360 px con texto 1.5x', (
        tester,
      ) async {
        visits.visits = [urgentOwnerVisit(status: status)];
        await openVisits(tester, width: 360, scale: 1.5);
        await openVisit(tester, 'urg1');
        expect(tester.takeException(), isNull);
        final handle = tester.ensureSemantics();
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        handle.dispose();
      });
    }
  });

  group('vet', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeVetRepository vets;
    late FakeVetAgendaRepository agenda;

    setUp(() {
      auth = FakeAuthRepository(userId: 'v1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'v1': const Account(
            role: AppRole.vet,
            displayName: 'Dra. Vera',
            vetStatus: VetStatus.approved,
          ),
        },
      );
      vets = FakeVetRepository(
        profile: const VetProfile(
          userId: 'v1',
          displayName: 'Dra. Vera',
          status: VetStatus.approved,
        ),
      );
      agenda = FakeVetAgendaRepository();
    });

    Future<void> openOnline(
      WidgetTester tester, {
      double width = 800,
      double scale = 1,
    }) async {
      view(tester, width: width, scale: scale);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          vets: vets,
          visits: visits,
          agenda: agenda,
          urgent: urgent,
          live: live,
          clock: clock,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vet-online')));
      await tester.pumpAndSettle();
    }

    testWidgets('"En línea" envía la presencia cada 30 s y la oferta no '
        'muestra la dirección', (tester) async {
      urgent.offers = [sampleOffer()];
      await openOnline(tester);
      expect(urgent.presence.single.$1, isTrue);
      clock.fire(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(urgent.presence, hasLength(2));

      expect(find.byKey(const Key('offer-off1')), findsOneWidget);
      expect(find.text('Urgencia en Ñuñoa'), findsOneWidget);
      expect(
        find.text('A unos 3,5 km · Perro · Medicina general'),
        findsOneWidget,
      );
      expect(find.textContaining('Ficticia'), findsNothing);
      expect(find.textContaining('+56'), findsNothing);
      expect(find.text('Quedan 1:00 para responder'), findsOneWidget);

      clock.advance(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(find.text('Quedan 0:45 para responder'), findsOneWidget);

      // Vencida: desaparece sin esperar al refresco.
      clock.advance(const Duration(seconds: 45));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('offer-off1')), findsNothing);
    });

    testWidgets('aceptar lleva a la visita con la dirección exacta', (
      tester,
    ) async {
      urgent.offers = [sampleOffer()];
      await openOnline(tester);
      await tester.tap(find.byKey(const Key('offer-accept-off1')));
      await tester.pumpAndSettle();
      expect(urgent.accepted, ['off1']);
      expect(find.text('Mis visitas'), findsWidgets);
      expect(find.byKey(const Key('vet-visit-exact-urg1')), findsOneWidget);
    });

    testWidgets('"ya tomada": avisa y quita la oferta', (tester) async {
      urgent
        ..offers = [sampleOffer()]
        ..acceptFailure = OfferFailureKind.taken;
      await openOnline(tester);
      await tester.tap(find.byKey(const Key('offer-accept-off1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('offer-failure-offer_taken')),
        findsOneWidget,
      );
      expect(find.text('Otro vet ya tomó esta urgencia'), findsOneWidget);
      expect(find.byKey(const Key('offer-off1')), findsNothing);
      expect(urgent.accepted, isEmpty);
    });

    testWidgets('rechazar quita la oferta', (tester) async {
      urgent.offers = [sampleOffer()];
      await openOnline(tester);
      await tester.tap(find.byKey(const Key('offer-reject-off1')));
      await tester.pumpAndSettle();
      expect(urgent.rejected, ['off1']);
      expect(find.byKey(const Key('offer-off1')), findsNothing);
    });

    testWidgets('al cerrar sesión se pone fuera de línea', (tester) async {
      await openOnline(tester);
      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
      expect(urgent.presence.last, (false, null));
    });

    testWidgets('en camino comparte la ubicación y deja de hacerlo al '
        'llegar', (tester) async {
      visits.visits = [
        vetVisit(id: 'urg1', status: VisitStatus.enRoute, exact: true),
      ];
      view(tester);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          vets: vets,
          visits: visits,
          agenda: agenda,
          urgent: urgent,
          live: live,
          clock: clock,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vet-open-visits')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vet-live-urg1')), findsOneWidget);
      final session = live.last('urg1')!;
      expect(session.sent, hasLength(1));
      clock.fire(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(session.sent, hasLength(2));

      await tester.tap(find.byKey(const Key('vet-action-urg1-arrived')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vet-live-urg1')), findsNothing);
      expect(session.ended, isTrue);
      expect(session.left, isTrue);
    });

    testWidgets('oferta sin desbordes a 360 px con texto 1.5x', (tester) async {
      urgent.offers = [sampleOffer()];
      await openOnline(tester, width: 360, scale: 1.5);
      expect(find.byKey(const Key('offer-off1')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final handle = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  });
}
