import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

void main() {
  group('máquina de estados (cliente)', () {
    test('el vet solo ofrece las transiciones válidas', () {
      String wires(VisitStatus s) =>
          vetActionsFor(s).map((a) => a.to.wire).join(',');
      expect(wires(VisitStatus.pendingVet), 'accepted,rejected');
      expect(wires(VisitStatus.accepted), 'en_route,cancelled_vet');
      expect(wires(VisitStatus.enRoute), 'arrived,cancelled_vet');
      expect(wires(VisitStatus.arrived), 'in_progress,cancelled_vet');
      expect(wires(VisitStatus.inProgress), 'completed');
      for (final s in [
        VisitStatus.completed,
        VisitStatus.expired,
        VisitStatus.rejected,
        VisitStatus.cancelledOwner,
        VisitStatus.cancelledVet,
      ]) {
        expect(vetActionsFor(s), isEmpty, reason: s.wire);
      }
    });

    test('estados abiertos, activos y cancelables', () {
      expect(VisitStatus.pendingVet.isOpen, isTrue);
      expect(VisitStatus.pendingVet.isAssignedActive, isFalse);
      expect(VisitStatus.inProgress.isAssignedActive, isTrue);
      expect(VisitStatus.completed.isOpen, isFalse);
      expect(VisitStatus.arrived.ownerCanCancel, isFalse);
      expect(VisitStatus.enRoute.ownerCanCancel, isTrue);
      expect(VisitStatus.parse('in_progress'), VisitStatus.inProgress);
    });
  });

  group('JSON del servidor', () {
    test('la vista del vet sin dirección exacta', () {
      final v = Visit.fromJson(const {
        'id': 'x',
        'viewer': 'vet',
        'mode': 'scheduled',
        'status': 'pending_vet',
        'scheduled_at': '2026-11-20T13:30:00+00:00',
        'commune_name': 'Ñuñoa',
        'distance_km': 8.0,
        'vet_payout': 24216,
        'exact': null,
      });
      expect(v.isOwnerView, isFalse);
      expect(v.exact, isNull);
      expect(v.distanceKm, 8);
      expect(v.canPay, isFalse);
    });

    test('la vista del dueño con precio congelado', () {
      final v = Visit.fromJson(const {
        'id': 'x',
        'viewer': 'owner',
        'mode': 'scheduled',
        'status': 'completed',
        'paid': false,
        'cancel_fee_now': null,
        'quote': {
          'quote_id': 'q1',
          'mode': 'scheduled',
          'base_price': 26990,
          'urgent_surcharge': 0,
          'billable_km': 3,
          'distance_surcharge': 1500,
          'discount': 0,
          'service_price': 28490,
          'platform_fee': 4274,
          'foundation_share': 855,
          'vet_payout': 24216,
          'extra_donation': 0,
          'total': 28490,
          'foundation_name': 'F',
          'distance_km': 8,
          'expires_at': '2026-11-20T13:30:00+00:00',
        },
      });
      expect(v.quote!.total, 28490);
      expect(v.canPay, isTrue);
      expect(v.canCancel, isFalse);
    });

    test('días libres desde el rango de Postgres', () {
      final t = parseTimeOff(
        't1',
        '["2026-11-20 03:00:00+00","2026-11-22 03:00:00+00")',
      )!;
      final from = DateTime.utc(2026, 11, 20, 3).toLocal();
      expect(t.from, DateTime(from.year, from.month, from.day));
      expect(t.to.difference(t.from).inDays, 1);
      expect(parseTimeOff('t2', 'empty'), isNull);
    });

    test('formatos', () {
      expect(formatSlot(DateTime(2026, 11, 18, 9, 5)), 'mié 18 nov · 09:05');
      expect(formatKm(7.5), '7,5 km');
      expect(isoDate(DateTime(2026, 1, 2)), '2026-01-02');
    });
  });
}
