import 'package:flutter/foundation.dart' show immutable;

/// Plan de suscripción del catálogo (`subscription_plans`, fase 10).
@immutable
class SubscriptionPlan {
  const new({
    required this.id,
    required this.slug,
    required this.name,
    required this.discountPct,
    required this.preventivePerYear,
    required this.waiveUrgent,
    required this.maxPets,
    required this.priceMonthly,
  });

  factory fromJson(Map<String, dynamic> j) => SubscriptionPlan(
    id: (j['id'] as num).toInt(),
    slug: j['slug'] as String,
    name: j['name'] as String,
    discountPct: (j['discount_pct'] as num).toDouble(),
    preventivePerYear: (j['preventive_per_year'] as num).toInt(),
    waiveUrgent: j['waive_urgent'] as bool? ?? false,
    maxPets: (j['max_pets'] as num).toInt(),
    priceMonthly: (j['price_monthly'] as num).toInt(),
  );

  final int id;
  final String slug;
  final String name;
  final double discountPct;
  final int preventivePerYear;
  final bool waiveUrgent;
  final int maxPets;
  final int priceMonthly;

  /// "10 %" o "12,5 %".
  String get discountLabel {
    final digits = discountPct % 1 == 0 ? 0 : 1;
    return '${discountPct.toStringAsFixed(digits).replaceAll('.', ',')} %';
  }

  /// Beneficios en frases cortas, en el orden en que se muestran.
  List<String> get benefits => [
    '$discountLabel de descuento en cada visita',
    if (preventivePerYear == 1)
      '1 visita preventiva al año sin tarifa base'
    else if (preventivePerYear > 1)
      '$preventivePerYear visitas preventivas al año sin tarifa base',
    if (waiveUrgent) 'Sin recargo por urgencia',
    if (maxPets == 1) 'Para 1 mascota' else 'Hasta $maxPets mascotas',
  ];
}

/// Estado de la suscripción.
enum SubscriptionStatus {
  active('active', 'Activa'),
  cancelled('cancelled', 'Cancelada'),
  ended('ended', 'Terminada');

  new(this.wire, this.label);

  final String wire;
  final String label;

  static SubscriptionStatus parse(String? v) =>
      values.firstWhere((s) => s.wire == v, orElse: () => ended);
}

@immutable
class SubscriptionPet {
  const new({required this.petId, required this.name, required this.active});

  factory fromJson(Map<String, dynamic> j) => SubscriptionPet(
    petId: j['pet_id'] as String,
    name: j['name'] as String? ?? 'Mascota',
    active: j['active'] as bool? ?? true,
  );

  final String petId;
  final String name;
  final bool active;
}

/// Suscripción del dueño (`my_subscription`). Las fechas son días de Chile;
/// [currentPeriodEnd] es exclusivo (los beneficios valen hasta el día antes).
@immutable
class Subscription {
  const new({
    required this.id,
    required this.status,
    required this.plan,
    required this.startedOn,
    required this.periodsPaid,
    required this.currentPeriodStart,
    required this.currentPeriodEnd,
    required this.renews,
    required this.benefitsActive,
    required this.preventiveUsed,
    required this.preventiveRemaining,
    required this.pets,
    this.cancelledAt,
  });

  factory fromJson(Map<String, dynamic> j) => Subscription(
    id: j['id'] as String,
    status: SubscriptionStatus.parse(j['status'] as String?),
    plan: SubscriptionPlan.fromJson((j['plan'] as Map).cast<String, dynamic>()),
    startedOn: DateTime.parse(j['started_on'] as String),
    periodsPaid: (j['periods_paid'] as num?)?.toInt() ?? 1,
    currentPeriodStart: DateTime.parse(j['current_period_start'] as String),
    currentPeriodEnd: DateTime.parse(j['current_period_end'] as String),
    renews: j['renews'] as bool? ?? false,
    cancelledAt: switch (j['cancelled_at']) {
      final String s => DateTime.parse(s).toLocal(),
      _ => null,
    },
    benefitsActive: j['benefits_active'] as bool? ?? false,
    preventiveUsed: (j['preventive_used'] as num?)?.toInt() ?? 0,
    preventiveRemaining: (j['preventive_remaining'] as num?)?.toInt() ?? 0,
    pets: [
      for (final p in (j['pets'] as List?) ?? const [])
        SubscriptionPet.fromJson((p as Map).cast<String, dynamic>()),
    ],
  );

  final String id;
  final SubscriptionStatus status;
  final SubscriptionPlan plan;
  final DateTime startedOn;
  final int periodsPaid;
  final DateTime currentPeriodStart;
  final DateTime currentPeriodEnd;
  final bool renews;
  final DateTime? cancelledAt;
  final bool benefitsActive;
  final int preventiveUsed;
  final int preventiveRemaining;
  final List<SubscriptionPet> pets;

  /// Último día con beneficios (el día anterior al fin exclusivo).
  DateTime get lastBenefitDay =>
      currentPeriodEnd.subtract(const Duration(days: 1));
}
