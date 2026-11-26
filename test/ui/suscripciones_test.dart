import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/subscription_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/subscription.dart';
import 'package:proyecto_felix/ui/features/owner/views/quote_breakdown.dart';

import '../helpers/fakes.dart';

/// Fase 10: "Mi plan" (contratar, mascotas, cancelar) y el plan en el
/// desglose del precio, con repositorios falsos.
void main() {
  Pet pet(String id, String name) => Pet(
    id: id,
    name: name,
    speciesId: 2,
    speciesName: 'Gato',
    sex: PetSex.female,
    sterilized: true,
    active: true,
  );

  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeSubscriptionRepository subs;
  late FakePetRepository pets;

  setUp(() {
    auth = FakeAuthRepository(userId: 'o1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {'o1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
    subs = FakeSubscriptionRepository();
    pets = FakePetRepository(pets: [pet('p1', 'Albita'), pet('p2', 'Toby')]);
  });

  Future<void> openPlan(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        auth: auth,
        profiles: profiles,
        pets: pets,
        subscriptions: subs,
        retry: (_, _) => null,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('owner-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-plan')));
    await tester.pumpAndSettle();
  }

  testWidgets('sin plan muestra el catálogo con sus beneficios', (
    tester,
  ) async {
    await openPlan(tester);
    expect(find.text('Elige un plan'), findsOneWidget);
    expect(find.byKey(const Key('plan-basico')), findsOneWidget);
    expect(find.byKey(const Key('plan-familia')), findsOneWidget);
    expect(find.text(r'$4.990'), findsOneWidget);
    expect(find.text('10 % de descuento en cada visita'), findsOneWidget);
    expect(find.text('Sin recargo por urgencia'), findsOneWidget);
    expect(find.text('Hasta 4 mascotas'), findsOneWidget);
    expect(find.textContaining('Pago simulado'), findsOneWidget);
  });

  testWidgets('contrata Básico eligiendo una mascota', (tester) async {
    await openPlan(tester);
    await tester.tap(find.byKey(const Key('plan-subscribe-basico')));
    await tester.pumpAndSettle();
    expect(find.text('Elige la mascota'), findsOneWidget);
    final confirm = find.byKey(const Key('plan-pets-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const Key('plan-pet-p1')));
    await tester.pump();
    // Con una sola mascota permitida, elegir otra reemplaza.
    await tester.tap(find.byKey(const Key('plan-pet-p2')));
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(subs.subscribeCalls.single.$1, 1);
    expect(subs.subscribeCalls.single.$2, ['p2']);
    expect(find.text('Plan Básico contratado'), findsOneWidget);
    expect(find.byKey(const Key('plan-current')), findsOneWidget);
    expect(find.text('Activa'), findsOneWidget);
    expect(find.textContaining('te quedan 1 de 1'), findsOneWidget);
    // Con un plan activo no se ofrece contratar otro.
    expect(find.byKey(const Key('plan-familia')), findsNothing);
  });

  testWidgets('Familia permite varias mascotas y se cambian después', (
    tester,
  ) async {
    subs.current = null;
    await openPlan(tester);
    await tester.tap(find.byKey(const Key('plan-subscribe-familia')));
    await tester.pumpAndSettle();
    expect(find.text('Elige hasta 4 mascotas'), findsOneWidget);
    await tester.tap(find.byKey(const Key('plan-pet-p1')));
    await tester.tap(find.byKey(const Key('plan-pet-p2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('plan-pets-confirm')));
    await tester.pumpAndSettle();
    expect(subs.subscribeCalls.single.$1, 3);
    expect(subs.subscribeCalls.single.$2, ['p1', 'p2']);

    await tester.tap(find.byKey(const Key('plan-edit-pets')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-pet-p2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('plan-pets-confirm')));
    await tester.pumpAndSettle();
    expect(subs.setPetsCalls.single, ['p1']);
  });

  testWidgets('cancelar mantiene los beneficios hasta fin del período', (
    tester,
  ) async {
    await openPlan(tester);
    await tester.tap(find.byKey(const Key('plan-subscribe-basico')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-pet-p1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('plan-pets-confirm')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plan-cancel')));
    await tester.pumpAndSettle();
    expect(find.textContaining('hasta el'), findsWidgets);
    await tester.tap(find.byKey(const Key('plan-cancel-confirm')));
    await tester.pumpAndSettle();

    expect(subs.cancelCalls, 1);
    expect(find.text('Cancelada'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('plan-period'))).data,
      startsWith('No se renovará'),
    );
    // Cancelada: puede contratar otro (el actual termina hoy).
    expect(find.text('Contratar otro plan'), findsOneWidget);
    expect(find.byKey(const Key('plan-cancel')), findsNothing);
  });

  testWidgets('el error del servidor se muestra al dueño', (tester) async {
    await openPlan(tester);
    subs.nextFailure = const SubscriptionFailure('El plan ya no está activo.');
    await tester.tap(find.byKey(const Key('plan-subscribe-basico')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-pet-p1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('plan-pets-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('El plan ya no está activo.'), findsOneWidget);
    expect(find.byKey(const Key('plan-current')), findsNothing);
  });

  testWidgets('sin mascotas no se puede contratar', (tester) async {
    pets = FakePetRepository();
    await openPlan(tester);
    expect(find.byKey(const Key('plan-no-pets')), findsOneWidget);
    final button = find.byKey(const Key('plan-subscribe-basico'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });

  group('desglose con plan', () {
    String text(WidgetTester tester, Key key) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(Text),
            matchRoot: true,
          ),
        )
        .map((t) => t.data)
        .join(' ');

    Future<void> pump(WidgetTester tester, Quote q) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: QuoteBreakdown(quote: q)),
        ),
      ),
    );

    Quote planQuote({
      required int discount,
      required int subsidy,
      bool preventive = false,
      VisitMode mode = VisitMode.scheduled,
    }) {
      // Lista 30.000: comisión 4.500, fundación 900, vet 25.500 (de lista).
      const list = 30000;
      final service = list - subsidy;
      return Quote(
        id: 'q1',
        mode: mode,
        basePrice: 30000,
        urgentSurcharge: 0,
        billableKm: 0,
        distanceSurcharge: 0,
        discount: discount,
        servicePrice: service,
        platformFee: 4500,
        foundationShare: 900,
        vetPayout: 25500,
        extraDonation: 0,
        total: service,
        foundationName: 'Fundación Demo',
        expiresAt: DateTime(2026, 11, 25, 18),
        distanceKm: 2,
        planName: 'Plus',
        isPreventive: preventive,
        planSubsidy: subsidy,
      );
    }

    testWidgets('descuento del plan y lo que cubre Felix', (tester) async {
      await pump(tester, planQuote(discount: 6000, subsidy: 6000));
      final d = text(tester, const Key('quote-discount'));
      expect(d, contains('Descuento de tu plan Plus'));
      expect(d, contains(r'-$6.000'));
      expect(text(tester, const Key('quote-total')), contains(r'$24.000'));
      // El vet cobra su tarifa completa.
      expect(text(tester, const Key('quote-vet')), contains(r'$25.500'));
      expect(
        text(tester, const Key('quote-plan-subsidy')),
        contains(r'-$6.000'),
      );
    });

    testWidgets('preventiva incluida', (tester) async {
      await pump(
        tester,
        planQuote(discount: 30000, subsidy: 30000, preventive: true),
      );
      expect(
        text(tester, const Key('quote-discount')),
        contains('Preventiva incluida en tu plan Plus'),
      );
      expect(text(tester, const Key('quote-total')), contains(r'$0'));
    });

    testWidgets('urgencia sin recargo con el plan', (tester) async {
      await pump(
        tester,
        planQuote(discount: 6000, subsidy: 15000, mode: VisitMode.urgent),
      );
      expect(
        text(tester, const Key('quote-urgent-waived')),
        contains('Sin recargo con tu plan Plus'),
      );
    });

    test('Quote.fromJson lee el plan del servidor', () {
      final q = Quote.fromJson(const {
        'quote_id': 'q9',
        'mode': 'scheduled',
        'base_price': 26990,
        'urgent_surcharge': 0,
        'billable_km': 0,
        'distance_surcharge': 0,
        'discount': 2699,
        'service_price': 24291,
        'platform_fee': 4049,
        'foundation_share': 810,
        'vet_payout': 22941,
        'extra_donation': 0,
        'total': 24291,
        'foundation_name': 'F',
        'expires_at': '2026-11-25T18:00:00Z',
        'plan': {'plan_id': 1, 'name': 'Básico', 'discount_pct': 10},
        'is_preventive': false,
        'plan_subsidy': 2699,
      });
      expect(q.planName, 'Básico');
      expect(q.planSubsidy, 2699);
      expect(q.isPreventive, isFalse);
      final none = Quote.fromJson(const {
        ...{
          'quote_id': 'q8',
          'base_price': 1,
          'urgent_surcharge': 0,
          'billable_km': 0,
          'distance_surcharge': 0,
          'discount': 0,
          'service_price': 1,
          'platform_fee': 0,
          'foundation_share': 0,
          'vet_payout': 1,
          'extra_donation': 0,
          'total': 1,
          'expires_at': '2026-11-25T18:00:00Z',
        },
        'plan': null,
      });
      expect(none.planName, isNull);
      expect(none.planSubsidy, 0);
    });
  });

  test('Subscription.fromJson lee la vista del servidor', () {
    final s = Subscription.fromJson(const {
      'id': 's1',
      'status': 'cancelled',
      'plan': {
        'id': 2,
        'slug': 'plus',
        'name': 'Plus',
        'discount_pct': 20.0,
        'preventive_per_year': 2,
        'waive_urgent': true,
        'max_pets': 1,
        'price_monthly': 9990,
      },
      'started_on': '2026-01-31',
      'periods_paid': 2,
      'current_period_start': '2026-02-28',
      'current_period_end': '2026-03-31',
      'renews': false,
      'cancelled_at': '2026-03-01T12:00:00Z',
      'benefits_active': true,
      'preventive_used': 1,
      'preventive_remaining': 1,
      'pets': [
        {'pet_id': 'p1', 'name': 'Albita', 'active': true},
      ],
    });
    expect(s.status, SubscriptionStatus.cancelled);
    expect(s.plan.discountLabel, '20 %');
    expect(s.lastBenefitDay, DateTime(2026, 3, 30));
    expect(s.pets.single.name, 'Albita');
    expect(
      s.plan.benefits,
      contains(
        '2 visitas preventivas al año sin '
        'tarifa base',
      ),
    );
  });
}
