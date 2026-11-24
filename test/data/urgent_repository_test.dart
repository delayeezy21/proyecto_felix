import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proyecto_felix/data/repositories/urgent_repository.dart';
import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Repositorio real contra un PostgREST falso (MockClient): verifica los
/// parámetros de cada RPC y la traducción de errores, sin levantar Supabase.
void main() {
  late List<(String, Map<String, dynamic>?)> calls;
  late http.Response Function(String rpc) respond;

  SupabaseUrgentRepository repo() {
    final client = SupabaseClient(
      'http://127.0.0.1:54321',
      'clave-de-prueba',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((req) async {
        final rpc = req.url.pathSegments.last;
        final body = req.body.isEmpty ? null : jsonDecode(req.body);
        calls.add((rpc, body is Map ? body.cast<String, dynamic>() : null));
        final r = respond(rpc);
        // PostgREST lee la petición original desde la respuesta.
        return http.Response(
          r.body,
          r.statusCode,
          headers: r.headers,
          request: req,
        );
      }),
    );
    addTearDown(client.dispose);
    return SupabaseUrgentRepository(client);
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response pgError(String code, String message, {String? hint}) => json({
    'code': code,
    'message': message,
    'details': null,
    'hint': hint,
  }, 400);

  setUp(() {
    calls = [];
    respond = (_) => json({});
  });

  test('request_urgent_visit envía solo lo elegido por el dueño', () async {
    respond = (_) => json({
      'id': 'v1',
      'viewer': 'owner',
      'mode': 'urgent',
      'status': 'searching',
      'confirm_deadline': '2026-11-24T15:10:00+00:00',
    });
    final v = await repo().request(petId: 'p1', addressId: 'a1', notes: '  ');
    expect(v.status, VisitStatus.searching);
    expect(calls.single.$1, 'request_urgent_visit');
    expect(calls.single.$2, {
      'p_pet_id': 'p1',
      'p_address_id': 'a1',
      'p_specialty_id': null,
      'p_foundation_id': null,
      'p_extra_donation': 0,
      'p_notes': null,
    });
  });

  test('set_vet_presence: en línea con posición, fuera sin posición', () async {
    final r = repo();
    await r.setPresence(online: true, at: const GeoPoint(-33.45, -70.6));
    await r.setPresence(online: false, at: const GeoPoint(-33.45, -70.6));
    expect(calls[0].$2, {'p_online': true, 'p_lat': -33.45, 'p_lng': -70.6});
    expect(calls[1].$2, {'p_online': false, 'p_lat': null, 'p_lng': null});
  });

  test('my_offers', () async {
    respond = (_) => json([
      {
        'offer_id': 'o1',
        'visit_id': 'v1',
        'batch': 1,
        'created_at': '2026-11-24T15:00:00+00:00',
        'expires_at': '2026-11-24T15:01:00+00:00',
        'commune_name': 'Ñuñoa',
        'distance_km': 2.5,
        'species_name': 'Perro',
        'specialty_name': 'Medicina general',
        'service_price': 35087,
        'vet_payout': 29824,
      },
    ]);
    final offers = await repo().myOffers();
    expect(offers.single.offerId, 'o1');
    expect(offers.single.distanceKm, 2.5);
  });

  for (final kind in OfferFailureKind.values) {
    test('accept_offer con hint ${kind.hint} → OfferFailure', () async {
      respond = (_) => pgError('22023', 'mensaje', hint: kind.hint);
      await expectLater(
        repo().accept('o1'),
        throwsA(isA<OfferFailure>().having((e) => e.kind, 'kind', kind)),
      );
      expect(calls.single.$2, {'p_offer_id': 'o1'});
    });
  }

  test('errores 22023 sin hint muestran el mensaje del servidor', () async {
    respond = (_) => pgError('22023', 'Tienes demasiadas visitas abiertas');
    await expectLater(
      repo().request(petId: 'p1', addressId: 'a1'),
      throwsA(
        isA<VisitFailure>()
            .having((e) => e is OfferFailure, 'oferta', isFalse)
            .having(
              (e) => e.message,
              'message',
              'Tienes demasiadas visitas abiertas',
            ),
      ),
    );
  });

  test('42501 de rol se muestra; otro 42501 queda genérico', () async {
    respond = (_) =>
        pgError('42501', 'Solo un veterinario informa su disponibilidad');
    await expectLater(
      repo().setPresence(online: false),
      throwsA(
        isA<VisitFailure>().having(
          (e) => e.message,
          'message',
          'Solo un veterinario informa su disponibilidad',
        ),
      ),
    );
    respond = (_) => pgError('42501', 'permission denied for table x');
    await expectLater(
      repo().myOffers(),
      throwsA(
        isA<VisitFailure>().having(
          (e) => e.message,
          'message',
          'No tienes permiso para esta acción.',
        ),
      ),
    );
  });

  test('urgent_search_status nulo (no es del dueño) es un error', () async {
    respond = (_) => http.Response(
      'null',
      200,
      headers: {'content-type': 'application/json'},
    );
    await expectLater(repo().searchStatus('v1'), throwsA(isA<VisitFailure>()));
  });
}
