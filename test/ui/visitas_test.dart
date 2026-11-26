import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

import '../helpers/fakes.dart';

void main() {
  void bigView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(800, 2600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('visitas del dueño', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeVisitRepository visits;
    late FakeQuoteRepository quotes;
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
      visits = FakeVisitRepository();
      quotes = FakeQuoteRepository();
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

    Future<void> openVisits(WidgetTester tester) async {
      bigView(tester);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          pets: pets,
          addresses: addresses,
          quotes: quotes,
          visits: visits,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Visitas'));
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, Key field, String option) async {
      await tester.tap(find.byKey(field));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option).last);
      await tester.pumpAndSettle();
    }

    testWidgets('sin visitas muestra el estado vacío', (tester) async {
      await openVisits(tester);
      expect(find.byKey(const Key('visits-empty')), findsOneWidget);
      expect(find.byKey(const Key('visit-book')), findsOneWidget);
    });

    testWidgets('elige vet y horario, cotiza con ese vet y reserva', (
      tester,
    ) async {
      final slot = DateTime(2026, 11, 20, 10, 30);
      visits.vets = [
        AvailableVet(
          vetId: 'v1',
          displayName: 'Dra. Vera',
          bio: 'Perros y gatos (ficticia).',
          distanceKm: 8,
          slots: [slot, DateTime(2026, 11, 20, 11)],
        ),
      ];
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-book')));
      await tester.pumpAndSettle();

      // Valida antes de buscar.
      await tester.tap(find.byKey(const Key('book-search')));
      await tester.pumpAndSettle();
      expect(find.text('Elige la mascota'), findsOneWidget);
      expect(visits.searches, isEmpty);

      await pick(tester, const Key('book-pet'), 'Firulais · Perro');
      await pick(tester, const Key('book-address'), 'Casa · Ñuñoa');
      await pick(tester, const Key('book-specialty'), 'Medicina general');
      await tester.tap(find.byKey(const Key('book-search')));
      await tester.pumpAndSettle();

      expect(visits.searches.single.$1, 'p1');
      expect(find.text('Dra. Vera'), findsOneWidget);
      expect(find.text('A unos 8 km'), findsOneWidget);

      await tester.tap(find.byKey(const Key('slot-v1-0')));
      await tester.pumpAndSettle();
      final q = quotes.requests.single;
      expect(q.vetId, 'v1', reason: 'la cotización agendada lleva el vet');
      expect(q.petId, 'p1');
      expect(find.byKey(const Key('quote-breakdown')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('book-notes')),
        'Control anual',
      );
      await tester.ensureVisible(find.byKey(const Key('book-confirm')));
      await tester.tap(find.byKey(const Key('book-confirm')));
      await tester.pumpAndSettle();

      final b = visits.bookings.single;
      expect(b['quote'], 'q1');
      expect(b['vet'], 'v1');
      expect(b['pet'], 'p1');
      expect(b['address'], 'a1');
      expect(b['at'], slot);
      expect(b['notes'], 'Control anual');
      // Queda en el detalle de la visita nueva.
      expect(find.byKey(const Key('visit-status-pending_vet')), findsOneWidget);
      expect(find.byKey(const Key('visit-deadline')), findsOneWidget);
    });

    testWidgets('sin horarios lo indica', (tester) async {
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-book')));
      await tester.pumpAndSettle();
      await pick(tester, const Key('book-pet'), 'Firulais · Perro');
      await pick(tester, const Key('book-address'), 'Casa · Ñuñoa');
      await pick(tester, const Key('book-specialty'), 'Medicina general');
      await tester.tap(find.byKey(const Key('book-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('book-no-vets')), findsOneWidget);
    });

    testWidgets('muestra el error del servidor al reservar', (tester) async {
      visits.vets = [
        AvailableVet(
          vetId: 'v1',
          displayName: 'Dra. Vera',
          distanceKm: 3,
          slots: [DateTime(2026, 11, 20, 10, 30)],
        ),
      ];
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-book')));
      await tester.pumpAndSettle();
      await pick(tester, const Key('book-pet'), 'Firulais · Perro');
      await pick(tester, const Key('book-address'), 'Casa · Ñuñoa');
      await pick(tester, const Key('book-specialty'), 'Medicina general');
      await tester.tap(find.byKey(const Key('book-search')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('slot-v1-0')));
      await tester.pumpAndSettle();
      visits.nextFailure = const VisitFailure(
        'El horario ya no está disponible. Elige otro.',
      );
      await tester.ensureVisible(find.byKey(const Key('book-confirm')));
      await tester.tap(find.byKey(const Key('book-confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text('El horario ya no está disponible. Elige otro.'),
        findsOneWidget,
      );
    });

    testWidgets('cancelar dentro de las 2 h advierte el cargo', (tester) async {
      visits
        ..visits = [
          ownerVisit(status: VisitStatus.accepted, cancelFeeNow: 5000),
        ]
        ..cancelFee = 5000;
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-vis1')));
      await tester.pumpAndSettle();
      expect(find.textContaining(r'cargo $5.000'), findsOneWidget);
      await tester.tap(find.byKey(const Key('visit-cancel')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(r'se cobrará un cargo de $5.000'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('reason-field')), 'Viaje');
      await tester.tap(find.byKey(const Key('reason-confirm')));
      await tester.pumpAndSettle();
      expect(visits.transitions.single, (
        'vis1',
        VisitStatus.cancelledOwner,
        'Viaje',
      ));
      expect(find.byKey(const Key('visit-cancel-fee')), findsOneWidget);
    });

    testWidgets('cancelar con anticipación es gratis', (tester) async {
      visits.visits = [ownerVisit(status: VisitStatus.accepted)];
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-vis1')));
      await tester.pumpAndSettle();
      expect(find.text('Cancelar sin costo'), findsOneWidget);
    });

    testWidgets('en curso no se paga ni se cancela', (tester) async {
      visits.visits = [ownerVisit(status: VisitStatus.inProgress)];
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-vis1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('visit-pay')), findsNothing);
      expect(find.byKey(const Key('visit-cancel')), findsNothing);
    });

    testWidgets('completada: pantalla de pago simulado', (tester) async {
      visits.visits = [ownerVisit(status: VisitStatus.completed)];
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('visit-vis1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('visit-pay')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pago simulado'), findsWidgets);

      await tester.tap(find.byKey(const Key('pay-fail')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pay-failed')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pay-confirm')));
      await tester.pumpAndSettle();
      expect(visits.payments, [('vis1', true), ('vis1', false)]);
      expect(find.byKey(const Key('pay-ok')), findsOneWidget);
    });
  });

  group('visitas del vet', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeVisitRepository visits;
    late FakeVetAgendaRepository agenda;
    late FakeVetRepository vets;

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
      visits = FakeVisitRepository();
      agenda = FakeVetAgendaRepository();
      vets = FakeVetRepository(
        profile: const VetProfile(
          userId: 'v1',
          displayName: 'Dra. Vera',
          status: VetStatus.approved,
        ),
      );
    });

    Future<void> open(WidgetTester tester) async {
      bigView(tester);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          vets: vets,
          visits: visits,
          agenda: agenda,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('la agenda avisa si falta el punto de partida', (tester) async {
      visits.visits = [vetVisit()];
      await open(tester);
      expect(find.text('Mis visitas (1 por confirmar)'), findsOneWidget);
      expect(find.byKey(const Key('vet-base-missing')), findsOneWidget);
    });

    testWidgets('confirma y avanza la visita; la dirección exacta solo '
        'con la visita activa', (tester) async {
      visits.visits = [vetVisit()];
      await open(tester);
      await tester.tap(find.byKey(const Key('vet-open-visits')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('vet-visit-approx-vis1')), findsOneWidget);
      expect(find.textContaining('Av. Ficticia'), findsNothing);
      expect(find.textContaining('a unos 8 km'), findsOneWidget);

      await tester.tap(find.byKey(const Key('vet-action-vis1-accepted')));
      await tester.pumpAndSettle();
      expect(visits.transitions.last.$2, VisitStatus.accepted);
      expect(find.byKey(const Key('vet-visit-exact-vis1')), findsOneWidget);
      expect(find.textContaining('+56 9 1111 1111'), findsOneWidget);

      for (final s in [
        VisitStatus.enRoute,
        VisitStatus.arrived,
        VisitStatus.inProgress,
        VisitStatus.completed,
      ]) {
        await tester.tap(find.byKey(Key('vet-action-vis1-${s.wire}')));
        await tester.pumpAndSettle();
        expect(visits.transitions.last.$2, s);
      }
      // Cerrada: vuelve a ver solo lo aproximado.
      expect(find.byKey(const Key('vet-visit-exact-vis1')), findsNothing);
      expect(find.byKey(const Key('vet-visit-approx-vis1')), findsOneWidget);
    });

    testWidgets('rechazar pide confirmación y motivo', (tester) async {
      visits.visits = [vetVisit()];
      await open(tester);
      await tester.tap(find.byKey(const Key('vet-open-visits')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vet-action-vis1-rejected')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('reason-field')), 'Sin cupo');
      await tester.tap(find.byKey(const Key('reason-confirm')));
      await tester.pumpAndSettle();
      expect(visits.transitions.single, (
        'vis1',
        VisitStatus.rejected,
        'Sin cupo',
      ));
    });

    testWidgets('muestra el error del servidor al avanzar', (tester) async {
      visits
        ..visits = [vetVisit(status: VisitStatus.accepted, exact: true)]
        ..nextFailure = const VisitFailure(
          'Puedes marcar "en camino" desde 2 horas antes de la visita',
        );
      await open(tester);
      await tester.tap(find.byKey(const Key('vet-open-visits')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vet-action-vis1-en_route')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('snack-error')), findsOneWidget);
    });
  });

  group('admin', () {
    testWidgets('ve solo el resumen agregado de visitas', (tester) async {
      bigView(tester);
      final auth = FakeAuthRepository(userId: 'ad1');
      final profiles = FakeProfileRepository(
        auth,
        accounts: {
          'ad1': const Account(role: AppRole.admin, displayName: 'Admin'),
        },
      );
      final visits = FakeVisitRepository()
        ..summary = const [
          VisitStatusCount(
            mode: VisitMode.scheduled,
            status: VisitStatus.completed,
            total: 3,
          ),
        ];
      await tester.pumpWidget(
        testApp(auth: auth, profiles: profiles, visits: visits),
      );
      await tester.pumpAndSettle();
      await openAdminSection(tester, 'Visitas');
      expect(
        find.byKey(const Key('admin-visits-scheduled-completed')),
        findsOneWidget,
      );
      expect(find.text('3'), findsOneWidget);
    });
  });
}
