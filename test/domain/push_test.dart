import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/push.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

void main() {
  const id = '6f1c2b8e-1d2a-4c3b-9e8f-0a1b2c3d4e5f';

  group('PushPayload (SPEC HU2.3: solo visit_id y el tipo de evento)', () {
    test('se arma con solo visit_id y event: no espera otros campos', () {
      final p = PushPayload.tryParse({'visit_id': id, 'event': 'offer_new'});
      expect(p, isNotNull);
      expect(p!.visitId, id);
      expect(p.event, isA<OfferNew>());
      expect(PushPayload.fields, {'visit_id', 'event'});
      expect(p.toData().keys.toSet(), PushPayload.fields);
    });

    test('descarta cualquier otro campo (no lo lee ni lo conserva)', () {
      final p = PushPayload.tryParse({
        'visit_id': id,
        'event': 'visit_en_route',
        'pet_name': 'Firulais',
        'address': 'Av. Ficticia 123',
        'diagnosis': 'otitis',
      });
      expect(p, isNotNull);
      expect(p!.toData(), {'visit_id': id, 'event': 'visit_en_route'});
      final text = p.text();
      for (final s in ['Firulais', 'Ficticia', 'otitis']) {
        expect(text.title, isNot(contains(s)));
        expect(text.body, isNot(contains(s)));
      }
    });

    test('reconoce los eventos del servidor', () {
      PushEvent? ev(String e) =>
          PushPayload.tryParse({'visit_id': id, 'event': e})?.event;
      expect(ev('offer_new'), isA<OfferNew>());
      expect(ev('offer_taken'), isA<OfferTaken>());
      expect(ev('offer_cancelled'), isA<OfferCancelled>());
      for (final s in VisitStatus.values) {
        final e = ev('visit_${s.wire}');
        expect(e, isA<VisitChanged>());
        expect((e! as VisitChanged).status, s);
        expect(e.wire, 'visit_${s.wire}');
      }
    });

    test('rechaza payloads incompletos o inválidos', () {
      expect(PushPayload.tryParse({'event': 'offer_new'}), isNull);
      expect(PushPayload.tryParse({'visit_id': id}), isNull);
      expect(
        PushPayload.tryParse({'visit_id': 'no-uuid', 'event': 'offer_new'}),
        isNull,
      );
      expect(
        PushPayload.tryParse({'visit_id': id, 'event': 'visit_otro'}),
        isNull,
      );
      expect(PushPayload.tryParse({'visit_id': id, 'event': 'x'}), isNull);
      expect(PushPayload.tryParse({'visit_id': 1, 'event': 2}), isNull);
    });

    test('el texto lo arma la app', () {
      final p = PushPayload.tryParse({'visit_id': id, 'event': 'offer_taken'});
      expect(p!.text().body, contains('Otro veterinario'));
      final v = PushPayload.tryParse({
        'visit_id': id,
        'event': 'visit_no_vet_found',
      });
      expect(v!.text().body, VisitStatus.noVetFound.label);
    });
  });
}
