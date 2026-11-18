import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';

void main() {
  test('QuoteRequest nunca envía montos al servidor', () {
    const r = QuoteRequest(
      petId: 'p',
      addressId: 'a',
      specialtyId: 1,
      mode: VisitMode.urgent,
      extraDonation: 2000,
    );
    final params = r.toParams();
    expect(params['p_mode'], 'urgent');
    expect(params['p_extra_donation'], 2000);
    expect(
      params.keys.where(
        (k) => RegExp('total|price|fee|share|payout|surcharge').hasMatch(k),
      ),
      isEmpty,
    );
  });

  test('Quote.fromJson lee el snapshot de quote_visit', () {
    final q = Quote.fromJson(const {
      'quote_id': 'q1',
      'mode': 'scheduled',
      'base_price': 25000,
      'urgent_surcharge': 0,
      'billable_km': 3,
      'distance_surcharge': 1500,
      'discount': 0,
      'service_price': 26500,
      'platform_fee': 3975,
      'foundation_share': 795,
      'vet_payout': 22525,
      'extra_donation': 1000,
      'total': 27500,
      'foundation_name': 'Fundación Demo',
      'distance_km': 8.0,
      'expires_at': '2026-11-17T21:30:00+00:00',
    });
    expect(q.total, 27500);
    expect(q.distanceKm, 8.0);
    expect(q.distancePending, isFalse);
    expect(q.vetPayout + q.platformFee, q.servicePrice);
  });

  test('distancia pendiente cuando aún no hay vet', () {
    final q = Quote.fromJson(const {
      'quote_id': 'q2',
      'mode': 'urgent',
      'base_price': 25000,
      'urgent_surcharge': 7500,
      'billable_km': 0,
      'distance_surcharge': 0,
      'discount': 0,
      'service_price': 32500,
      'platform_fee': 4875,
      'foundation_share': 975,
      'vet_payout': 27625,
      'extra_donation': 0,
      'total': 32500,
      'foundation_name': null,
      'distance_km': null,
      'expires_at': '2026-11-17T21:30:00Z',
    });
    expect(q.mode, VisitMode.urgent);
    expect(q.distancePending, isTrue);
    expect(q.foundationName, 'Fundación');
  });

  test('validación y lectura de la donación', () {
    expect(validateDonation(''), isNull);
    expect(validateDonation('5.000'), isNull);
    expect(validateDonation('abc'), isNotNull);
    expect(validateDonation('1.000.001'), isNotNull);
    expect(parseDonation('5.000'), 5000);
    expect(parseDonation(''), 0);
  });

  test('FoundationDraft limpia los campos vacíos', () {
    const d = FoundationDraft(name: ' Patitas ', description: ' ', website: '');
    expect(d.toRow(), {
      'name': 'Patitas',
      'description': null,
      'website': null,
    });
  });

  test('etiqueta del mes en español', () {
    expect(monthLabel(DateTime(2026, 11)), 'noviembre 2026');
  });
}
