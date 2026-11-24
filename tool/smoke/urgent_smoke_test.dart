// Smoke de la fase 8 (urgencias) con los repositorios y servicios REALES de
// la app contra Supabase local (QA 37c4e3c).
//
// La app solo se había probado con un PostgREST falso: aquí se comprueba que
// los nombres de parámetros y las formas JSON de `SupabaseUrgentRepository`,
// `SupabaseVisitRepository` y `SupabaseLiveLocationService` coinciden con
// las RPC y el canal Realtime privado reales.
//
// Uso (con `supabase start`):
//   flutter test tool/smoke/urgent_smoke_test.dart \
//     --dart-define=SUPABASE_URL=http://127.0.0.1:<puerto> \
//     --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
//     --dart-define=SUPABASE_SERVICE_KEY=...
// Crea usuarios @test.local y los borra al final.

import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/urgent_repository.dart';
import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/data/services/live_location_service.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'http://127.0.0.1:54321',
);
const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const _service = String.fromEnvironment('SUPABASE_SERVICE_KEY');
const _password = 'Felix2026';

// Dirección ficticia en Ñuñoa (como el E2E de urgencias).
const _homeLat = -33.4569;
const _homeLng = -70.5974;

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

final SupabaseClient _admin = _client(_service);
final _created = <String>[];

Future<SupabaseClient> _newUser(String tag) async {
  final email =
      'smoke-f8-$tag-${DateTime.now().microsecondsSinceEpoch}@test.local';
  final r = await _admin.auth.admin.createUser(
    AdminUserAttributes(email: email, password: _password, emailConfirm: true),
  );
  _created.add(r.user!.id);
  final c = _client(_key);
  await c.auth.signInWithPassword(email: email, password: _password);
  return c;
}

Future<void> _register(SupabaseClient c, String role, String name) async {
  final terms = await c.rpc<dynamic>(
    'current_legal_version',
    params: {'p_kind': 'terms'},
  );
  final privacy = await c.rpc<dynamic>(
    'current_legal_version',
    params: {'p_kind': 'privacy'},
  );
  final nunoa = await c
      .from('communes')
      .select('id')
      .eq('name', 'Ñuñoa')
      .single();
  await c.rpc<void>(
    'complete_registration',
    params: {
      'p_role': role,
      'p_display_name': name,
      'p_phone': role == 'owner' ? '+56 9 4444 5555' : null,
      'p_terms_version': terms,
      'p_privacy_version': privacy,
      'p_commune_id': role == 'owner' ? nunoa['id'] : null,
    },
  );
}

String _uid(SupabaseClient c) => c.auth.currentUser!.id;

void main() {
  late SupabaseClient owner;
  late SupabaseClient owner2;
  late SupabaseClient vetA;
  late SupabaseClient vetB;
  late String pet;
  late String addr;
  late String pet2;
  late String addr2;
  late int perro;
  late int general;

  setUpAll(() async {
    if (_key.isEmpty || _service.isEmpty) {
      fail(
        'Faltan --dart-define SUPABASE_PUBLISHABLE_KEY / SUPABASE_SERVICE_KEY',
      );
    }
    owner = await _newUser('owner');
    owner2 = await _newUser('owner2');
    vetA = await _newUser('vet-a');
    vetB = await _newUser('vet-b');
    await _register(owner, 'owner', 'Smoke Dueña');
    await _register(owner2, 'owner', 'Smoke Dueño Dos');
    await _register(vetA, 'vet', 'Smoke Vet A');
    await _register(vetB, 'vet', 'Smoke Vet B');
    perro =
        (await owner
                .from('species')
                .select('id')
                .eq('slug', 'perro')
                .single())['id']
            as int;
    general =
        (await owner
                .from('specialties')
                .select('id')
                .eq('slug', 'general')
                .single())['id']
            as int;
    for (final v in [vetA, vetB]) {
      await _admin
          .from('vet_profiles')
          .update({'status': 'approved'})
          .eq('user_id', _uid(v));
      await _admin.from('vet_species').insert({
        'vet_id': _uid(v),
        'species_id': perro,
      });
      await _admin.from('vet_specialties').insert({
        'vet_id': _uid(v),
        'specialty_id': general,
      });
    }
    final nunoa = (await owner
        .from('communes')
        .select('id')
        .eq('name', 'Ñuñoa')
        .single())['id'];
    Future<(String, String)> petAndAddress(SupabaseClient c) async {
      final p = await c
          .from('pets')
          .insert({'owner_id': _uid(c), 'name': 'Rayo', 'species_id': perro})
          .select('id')
          .single();
      final a = await c
          .from('addresses')
          .insert({
            'owner_id': _uid(c),
            'label': 'Casa',
            'street_text': 'Pasaje Ficticio 789',
            'commune_id': nunoa,
            'lat': _homeLat,
            'lng': _homeLng,
          })
          .select('id')
          .single();
      return (p['id'] as String, a['id'] as String);
    }

    (pet, addr) = await petAndAddress(owner);
    (pet2, addr2) = await petAndAddress(owner2);
  });

  tearDownAll(() async {
    for (final id in _created) {
      await _admin.auth.admin.deleteUser(id);
    }
  });

  test(
    'urgencia de punta a punta con los repositorios y el canal reales',
    () async {
      final ownerRepo = SupabaseUrgentRepository(owner);
      final aRepo = SupabaseUrgentRepository(vetA);
      final bRepo = SupabaseUrgentRepository(vetB);

      // Presencia (params p_online/p_lat/p_lng).
      await aRepo.setPresence(
        online: true,
        at: const GeoPoint(_homeLat + 0.009, _homeLng),
      );
      await bRepo.setPresence(
        online: true,
        at: const GeoPoint(_homeLat + 0.018, _homeLng),
      );

      // Solicitud: forma de Visit + "hasta $X".
      final v = await ownerRepo.request(
        petId: pet,
        addressId: addr,
        notes: '  Cojea  ',
      );
      expect(v.status, VisitStatus.searching);
      expect(v.mode, VisitMode.urgent);
      expect(v.quote?.distancePending, isTrue);
      expect(v.quote?.maxTotal, 26990 + 8097 + 7500);
      expect(v.notes, 'Cojea');

      final s = await ownerRepo.searchStatus(v.id);
      expect(s.pendingOffers, 2);
      expect(s.status, VisitStatus.searching);

      // Ofertas: forma de UrgentOffer.
      final offA = await aRepo.myOffers();
      final offB = await bRepo.myOffers();
      expect(offA, hasLength(1));
      expect(offA.single.visitId, v.id);
      expect(offA.single.distanceKm, 1.0);
      expect(offA.single.communeName, 'Ñuñoa');
      expect(offA.single.vetPayout, isNotNull);

      // Aceptar: Visit con dirección exacta; el otro recibe OfferFailure.
      final accepted = await aRepo.accept(offA.single.offerId);
      expect(accepted.status, VisitStatus.accepted);
      expect(accepted.exact?.streetText, 'Pasaje Ficticio 789');
      expect(accepted.exact?.ownerPhone, isNotNull);
      await expectLater(
        bRepo.accept(offB.single.offerId),
        throwsA(
          isA<OfferFailure>().having(
            (f) => f.kind,
            'kind',
            OfferFailureKind.taken,
          ),
        ),
      );

      // my_visits del dueño: precio final con distancia (km enteros).
      final mine = (await SupabaseVisitRepository(
        owner,
      ).myVisits()).firstWhere((x) => x.id == v.id);
      expect(mine.status, VisitStatus.accepted);
      expect(mine.quote?.distanceKm, 1);
      expect(mine.vetName, 'Smoke Vet A');

      // Estado de búsqueda de una visita ajena: el repositorio lo trata como
      // "no encontrada".
      await expectLater(
        SupabaseUrgentRepository(owner2).searchStatus(v.id),
        throwsA(isA<VisitFailure>()),
      );

      // En camino + ubicación en vivo por el canal privado real.
      await SupabaseVisitRepository(vetA).transition(v.id, VisitStatus.enRoute);
      final ownerLive = SupabaseLiveLocationService(owner).join(v.id);
      final vetLive = SupabaseLiveLocationService(vetA).join(v.id);
      final got = <LiveEvent>[];
      final sub = ownerLive.events.listen(got.add);
      await Future<void>.delayed(const Duration(seconds: 3));
      await vetLive.send(
        LiveLocation(
          const GeoPoint(_homeLat + 0.004, _homeLng),
          DateTime.now(),
        ),
      );
      // QA-F8-01: sendEnd() pasa `const {}` y realtime_client lo modifica
      // (agrega `type`/`event`) → "Cannot modify unmodifiable map". Se anota
      // el error y se verifica al final para no cortar el resto del viaje.
      Object? endError;
      try {
        await vetLive.sendEnd();
      } on Object catch (e) {
        endError = e;
      }
      for (var i = 0; i < 50 && got.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(got.whereType<LivePosition>(), hasLength(1));
      expect(
        got.whereType<LivePosition>().single.location.point.lat,
        closeTo(_homeLat + 0.004, 1e-9),
      );
      final ownerGotEnd = got.whereType<LiveEnded>().length;
      await sub.cancel();
      await ownerLive.leave();
      await vetLive.leave();

      // Rechazo (p_offer_id) en otra urgencia: con el único vet libre
      // rechazando, la búsqueda queda sin vet.
      final v2 = await SupabaseUrgentRepository(owner2)
          .request(petId: pet2, addressId: addr2);
      final offB2 = await bRepo.myOffers();
      expect(offB2.single.visitId, v2.id);
      await bRepo.reject(offB2.single.offerId);
      final s2 = await SupabaseUrgentRepository(owner2).searchStatus(v2.id);
      expect(s2.status, VisitStatus.noVetFound);

      await aRepo.setPresence(online: false);
      await bRepo.setPresence(online: false);
      await SupabaseVisitRepository(owner)
          .transition(v.id, VisitStatus.cancelledOwner);

      expect(endError, isNull, reason: 'QA-F8-01: sendEnd() falla');
      expect(ownerGotEnd, 1, reason: 'QA-F8-01: el dueño no recibe "end"');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
