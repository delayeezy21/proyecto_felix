import 'package:proyecto_felix/data/repositories/subscription_repository.dart';
import 'package:proyecto_felix/domain/models/subscription.dart';

const planBasico = SubscriptionPlan(
  id: 1,
  slug: 'basico',
  name: 'Básico',
  discountPct: 10,
  preventivePerYear: 1,
  waiveUrgent: false,
  maxPets: 1,
  priceMonthly: 4990,
);

const planFamilia = SubscriptionPlan(
  id: 3,
  slug: 'familia',
  name: 'Familia',
  discountPct: 20,
  preventivePerYear: 2,
  waiveUrgent: true,
  maxPets: 4,
  priceMonthly: 14990,
);

/// Suscripciones en memoria (fase 10): una abierta por dueño, cancelar
/// conserva los beneficios hasta fin del período.
class FakeSubscriptionRepository implements SubscriptionRepository {
  List<SubscriptionPlan> planList = [planBasico, planFamilia];
  Subscription? current;
  final subscribeCalls = <(int, List<String>)>[];
  final setPetsCalls = <List<String>>[];
  int cancelCalls = 0;

  /// Error de la próxima llamada (una vez).
  Exception? nextFailure;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  Subscription _build(
    SubscriptionPlan plan,
    List<String> petIds, {
    SubscriptionStatus status = SubscriptionStatus.active,
  }) => Subscription(
    id: 'sub1',
    status: status,
    plan: plan,
    startedOn: DateTime(2026, 11, 25),
    periodsPaid: 1,
    currentPeriodStart: DateTime(2026, 11, 25),
    currentPeriodEnd: DateTime(2026, 12, 25),
    renews: status == SubscriptionStatus.active,
    benefitsActive: true,
    preventiveUsed: 0,
    preventiveRemaining: plan.preventivePerYear,
    pets: [
      for (final id in petIds)
        SubscriptionPet(petId: id, name: 'Mascota $id', active: true),
    ],
  );

  @override
  Future<List<SubscriptionPlan>> plans() async {
    _maybeFail();
    return planList;
  }

  @override
  Future<Subscription?> mine() async {
    _maybeFail();
    return current;
  }

  @override
  Future<Subscription> subscribe(int planId, List<String> petIds) async {
    subscribeCalls.add((planId, petIds));
    _maybeFail();
    if (current?.status == SubscriptionStatus.active) {
      throw const SubscriptionFailure(
        'Ya tienes una suscripción activa. Cancélala antes de cambiar de plan.',
      );
    }
    return current = _build(planList.firstWhere((p) => p.id == planId), petIds);
  }

  @override
  Future<Subscription> setPets(List<String> petIds) async {
    setPetsCalls.add(petIds);
    _maybeFail();
    final c = current!;
    return current = _build(c.plan, petIds, status: c.status);
  }

  @override
  Future<Subscription> cancel() async {
    cancelCalls++;
    _maybeFail();
    final c = current!;
    return current = _build(c.plan, [
      for (final p in c.pets) p.petId,
    ], status: SubscriptionStatus.cancelled);
  }
}
