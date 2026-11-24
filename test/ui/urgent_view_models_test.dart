import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/urgent_repository.dart';
import 'package:proyecto_felix/data/services/clock.dart';
import 'package:proyecto_felix/data/services/device_location.dart';
import 'package:proyecto_felix/data/services/live_location_service.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/features/urgent/view_models/urgent_providers.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

import '../helpers/fakes.dart';

/// ViewModels de urgencias con repositorios falsos y reloj manual.
void main() {
  late FakeAuthRepository auth;
  late FakeUrgentRepository urgent;
  late FakeVisitRepository visits;
  late FakeVetAgendaRepository agenda;
  late FakeDeviceLocation location;
  late FakeLiveLocationService live;
  late ManualClock clock;

  setUp(() {
    auth = FakeAuthRepository(userId: 'v1');
    urgent = FakeUrgentRepository();
    visits = FakeVisitRepository();
    urgent.visits = visits;
    agenda = FakeVetAgendaRepository();
    location = FakeDeviceLocation();
    live = FakeLiveLocationService();
    clock = ManualClock();
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        profileRepositoryProvider.overrideWithValue(
          FakeProfileRepository(
            auth,
            accounts: {
              'v1': const Account(
                role: AppRole.vet,
                displayName: 'Dra. Vera',
                vetStatus: VetStatus.approved,
              ),
            },
          ),
        ),
        urgentRepositoryProvider.overrideWithValue(urgent),
        visitRepositoryProvider.overrideWithValue(visits),
        vetAgendaRepositoryProvider.overrideWithValue(agenda),
        deviceLocationProvider.overrideWithValue(location),
        liveLocationServiceProvider.overrideWithValue(live),
        clockProvider.overrideWithValue(clock),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('UrgentSearchController', () {
    test(
      'consulta al abrir y cada 5 s; al terminar deja de consultar',
      () async {
        final c = container()..listen(urgentSearchProvider('urg1'), (_, _) {});
        await pumpEventQueue();
        expect(urgent.statusCalls, ['urg1']);
        expect(c.read(urgentSearchProvider('urg1')).value!.isSearching, isTrue);

        urgent.status = UrgentSearchStatus(
          visitId: 'urg1',
          status: VisitStatus.searching,
          searchUntil: DateTime(2026, 11, 24, 12, 10),
          radiusKm: 10,
          batches: 2,
          pendingOffers: 3,
        );
        clock.fire(UrgentSearchController.poll);
        await pumpEventQueue();
        expect(c.read(urgentSearchProvider('urg1')).value!.radiusKm, 10);

        var refreshed = 0;
        c.listen(myVisitsProvider, (_, _) => refreshed++);
        urgent.status = UrgentSearchStatus(
          visitId: 'urg1',
          status: VisitStatus.accepted,
          searchUntil: DateTime(2026, 11, 24, 12, 10),
          radiusKm: 10,
          batches: 2,
          pendingOffers: 0,
        );
        clock.fire(UrgentSearchController.poll);
        await pumpEventQueue();
        expect(refreshed, greaterThan(0), reason: 'refresca my_visits');
        final calls = urgent.statusCalls.length;
        clock.fire(UrgentSearchController.poll);
        await pumpEventQueue();
        expect(urgent.statusCalls.length, calls, reason: 'ya no consulta');
      },
    );

    test('un fallo puntual conserva el último estado', () async {
      final c = container()..listen(urgentSearchProvider('urg1'), (_, _) {});
      await pumpEventQueue();
      urgent.nextFailure = const VisitFailureForTest();
      clock.fire(UrgentSearchController.poll);
      await pumpEventQueue();
      expect(c.read(urgentSearchProvider('urg1')).hasValue, isTrue);
    });
  });

  group('VetPresenceController', () {
    test(
      'en línea con la posición del dispositivo y latido cada 30 s',
      () async {
        final c = container();
        await c.read(vetPresenceProvider.notifier).setOnline(online: true);
        expect(c.read(vetPresenceProvider).online, isTrue);
        expect(c.read(vetPresenceProvider).source, PresenceSource.device);
        expect(urgent.presence.single, (true, const GeoPoint(-33.45, -70.6)));

        clock.fire(VetPresenceController.heartbeat);
        await pumpEventQueue();
        expect(urgent.presence, hasLength(2));

        await c.read(vetPresenceProvider.notifier).goOffline();
        expect(urgent.presence.last, (false, null));
        expect(c.read(vetPresenceProvider).online, isFalse);
        clock.fire(VetPresenceController.heartbeat);
        await pumpEventQueue();
        expect(urgent.presence, hasLength(3), reason: 'sin latidos fuera');
      },
    );

    test('sin ubicación del dispositivo usa el punto de partida', () async {
      location.point = null;
      agenda.base = const VetBase(
        communeId: 102,
        point: GeoPoint(-33.46, -70.59),
      );
      final c = container();
      await c.read(vetPresenceProvider.notifier).setOnline(online: true);
      expect(c.read(vetPresenceProvider).source, PresenceSource.base);
      expect(urgent.presence.single.$2, const GeoPoint(-33.46, -70.59));
    });

    test('sin ubicación ni punto de partida no se pone en línea', () async {
      location.point = null;
      final c = container();
      await c.read(vetPresenceProvider.notifier).setOnline(online: true);
      final p = c.read(vetPresenceProvider);
      expect(p.online, isFalse);
      expect(p.error, contains('punto de partida'));
      expect(urgent.presence, isEmpty);
    });

    test(
      'fuera de línea sin haber estado en línea no llama al servidor',
      () async {
        final c = container();
        await c.read(vetPresenceProvider.notifier).goOffline();
        expect(urgent.presence, isEmpty);
      },
    );
  });

  group('VetOffersController', () {
    test('solo consulta en línea; aceptar ya tomada quita la oferta', () async {
      urgent.offers = [sampleOffer(), sampleOffer(id: 'off2')];
      final c = container()..listen(vetOffersProvider, (_, _) {});
      await pumpEventQueue();
      expect(c.read(vetOffersProvider).value, isEmpty, reason: 'fuera');

      await c.read(vetPresenceProvider.notifier).setOnline(online: true);
      await pumpEventQueue();
      expect(c.read(vetOffersProvider).value, hasLength(2));

      urgent.acceptFailure = OfferFailureKind.taken;
      await expectLater(
        c.read(vetOffersProvider.notifier).accept(sampleOffer()),
        throwsA(isA<OfferFailure>()),
      );
      expect(c.read(vetOffersProvider).value!.map((o) => o.offerId), ['off2']);

      urgent.acceptFailure = null;
      final v = await c
          .read(vetOffersProvider.notifier)
          .accept(sampleOffer(id: 'off2'));
      expect(v.exact, isNotNull, reason: 'la dirección llega al aceptar');
      expect(c.read(vetOffersProvider).value, isEmpty);
    });

    test('rechazar quita la oferta y se refresca cada 5 s', () async {
      urgent.offers = [sampleOffer()];
      final c = container()..listen(vetOffersProvider, (_, _) {});
      await c.read(vetPresenceProvider.notifier).setOnline(online: true);
      await pumpEventQueue();
      await c.read(vetOffersProvider.notifier).reject(sampleOffer());
      expect(urgent.rejected, ['off1']);
      expect(c.read(vetOffersProvider).value, isEmpty);

      urgent.offers = [sampleOffer(id: 'off3')];
      clock.fire(VetOffersController.poll);
      await pumpEventQueue();
      expect(c.read(vetOffersProvider).value!.single.offerId, 'off3');
    });
  });

  group('ubicación en vivo', () {
    test('el vet publica cada 5 s y al terminar avisa y sale', () async {
      final c = container();
      final sub = c.listen(vetLiveSharingProvider('urg1'), (_, _) {});
      await pumpEventQueue();
      final session = live.last('urg1')!;
      expect(session.sent, hasLength(1));
      clock.fire(VetLiveSharing.period);
      await pumpEventQueue();
      expect(session.sent, hasLength(2));
      expect(session.sent.last.toPayload().keys.toSet(), {'lat', 'lng', 'at'});

      sub.close();
      await pumpEventQueue();
      expect(session.ended, isTrue);
      expect(session.left, isTrue);
    });

    test('sin posición del dispositivo no envía nada (sin respaldo)', () async {
      location.point = null;
      final c = container()..listen(vetLiveSharingProvider('urg1'), (_, _) {});
      await pumpEventQueue();
      expect(live.last('urg1')!.sent, isEmpty);
      expect(c.read(vetLiveSharingProvider('urg1')).noPosition, isTrue);
    });

    test(
      'el dueño recibe posiciones y sale del canal al dejar de mirar',
      () async {
        final c = container();
        final seen = <LiveLocation>[];
        final sub = c.listen(
          ownerLiveLocationProvider('urg1'),
          (_, next) => seen.addAll([?next.value]),
        );
        final session = live.last('urg1')!;
        final point = LiveLocation(const GeoPoint(-33.44, -70.61), clock.now());
        session.controller.add(LivePosition(point));
        await pumpEventQueue();
        expect(seen.single.point, const GeoPoint(-33.44, -70.61));
        sub.close();
        await pumpEventQueue();
        expect(session.left, isTrue);
      },
    );
  });
}

class VisitFailureForTest implements Exception {
  const new();
}
