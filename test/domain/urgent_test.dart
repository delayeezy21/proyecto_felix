import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

void main() {
  test('UrgentSearchStatus lee la respuesta de urgent_search_status', () {
    final s = UrgentSearchStatus.fromJson(const {
      'visit_id': 'v1',
      'status': 'searching',
      'search_until': '2026-11-24T15:10:00+00:00',
      'radius_km': 10,
      'batches': 2,
      'pending_offers': 3,
    });
    expect(s.isSearching, isTrue);
    expect(s.radiusKm, 10);
    expect(s.batches, 2);
    expect(s.pendingOffers, 3);
    final first = UrgentSearchStatus.fromJson(const {
      'visit_id': 'v1',
      'status': 'no_vet_found',
      'search_until': '2026-11-24T15:10:00+00:00',
      'radius_km': null,
      'batches': 0,
      'pending_offers': 0,
    });
    expect(first.radiusKm, isNull);
    expect(first.status, VisitStatus.noVetFound);
  });

  test('UrgentOffer no tiene campos de dirección ni coordenadas', () {
    final o = UrgentOffer.fromJson(const {
      'offer_id': 'o1',
      'visit_id': 'v1',
      'batch': 1,
      'created_at': '2026-11-24T15:00:00+00:00',
      'expires_at': '2026-11-24T15:01:00+00:00',
      'commune_name': 'Ñuñoa',
      'distance_km': 3.5,
      'species_name': 'Perro',
      'specialty_name': 'Medicina general',
      'service_price': 35087,
      'vet_payout': 29824,
      // Aunque el servidor mandara más, el modelo no los guarda.
      'street_text': 'Av. Ficticia 123',
      'lat': -33.45,
    });
    expect(o.communeName, 'Ñuñoa');
    expect(o.distanceKm, 3.5);
    expect(o.vetPayout, 29824);
    expect(o.isExpiredAt(o.expiresAt), isTrue);
    expect(
      o.isExpiredAt(o.expiresAt.subtract(const Duration(seconds: 1))),
      isFalse,
    );
  });

  test('OfferFailureKind traduce el hint del servidor', () {
    expect(OfferFailureKind.parse('offer_taken'), OfferFailureKind.taken);
    expect(OfferFailureKind.parse('offer_expired'), OfferFailureKind.expired);
    expect(OfferFailureKind.parse('offer_closed'), OfferFailureKind.closed);
    expect(OfferFailureKind.parse(null), isNull);
    expect(OfferFailureKind.parse('otro'), isNull);
  });

  test('la cotización de una urgencia en búsqueda trae el tope', () {
    final q = Quote.fromJson(const {
      'quote_id': 'q1',
      'mode': 'urgent',
      'base_price': 26990,
      'urgent_surcharge': 8097,
      'billable_km': 0,
      'distance_surcharge': 0,
      'discount': 0,
      'service_price': 35087,
      'platform_fee': 5263,
      'foundation_share': 1053,
      'vet_payout': 29824,
      'extra_donation': 0,
      'total': 35087,
      'expires_at': '2026-11-24T15:30:00+00:00',
      'distance_km': null,
      'distance_pending': true,
      'max_distance_km': 20,
      'max_service_price': 42587,
      'max_total': 42587,
    });
    expect(q.distancePending, isTrue);
    expect(q.maxTotal, 42587);
    expect(q.maxServicePrice, 42587);
    expect(q.maxDistanceKm, 20);
  });

  test('LiveLocation acepta solo coordenadas válidas', () {
    final at = DateTime.utc(2026, 11, 24, 15);
    final loc = LiveLocation(const GeoPoint(-33.45, -70.6), at);
    final back = LiveLocation.tryParse(loc.toPayload());
    expect(back!.point, loc.point);
    expect(back.at.toUtc(), at);
    expect(loc.toPayload().keys.toSet(), {'lat', 'lng', 'at'});
    expect(LiveLocation.tryParse({'lat': 'x', 'lng': 1}), isNull);
    expect(LiveLocation.tryParse({'lat': 48.8, 'lng': 2.3}), isNull);
  });

  test('formatCountdown', () {
    final now = DateTime(2026, 11, 24, 12);
    expect(formatCountdown(now.add(const Duration(seconds: 545)), now), '9:05');
    expect(formatCountdown(now.add(const Duration(seconds: 59)), now), '0:59');
    expect(
      formatCountdown(now.subtract(const Duration(seconds: 1)), now),
      '0:00',
    );
  });
}
