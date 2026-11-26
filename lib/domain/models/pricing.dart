import 'package:flutter/foundation.dart' show immutable;

/// Tipo de visita que se cotiza.
enum VisitMode {
  scheduled('scheduled', 'Agendada'),
  urgent('urgent', 'Urgencia');

  new(this.wire, this.label);

  final String wire;
  final String label;

  static VisitMode parse(String? v) => v == urgent.wire ? urgent : scheduled;
}

/// Lo que el dueño elige para cotizar. No lleva montos: el precio lo calcula
/// solo el servidor (`quote_visit`).
@immutable
class QuoteRequest {
  const new({
    required this.petId,
    required this.addressId,
    required this.specialtyId,
    required this.mode,
    this.vetId,
    this.foundationId,
    this.extraDonation = 0,
  });

  final String petId;
  final String addressId;
  final int specialtyId;
  final VisitMode mode;
  final String? vetId;
  final String? foundationId;
  final int extraDonation;

  Map<String, Object?> toParams() => {
    'p_pet_id': petId,
    'p_address_id': addressId,
    'p_specialty_id': specialtyId,
    'p_mode': mode.wire,
    'p_vet_id': vetId,
    'p_foundation_id': foundationId,
    'p_extra_donation': extraDonation,
  };
}

/// Cotización persistente devuelta por el servidor (montos en CLP enteros).
@immutable
class Quote {
  const new({
    required this.id,
    required this.mode,
    required this.basePrice,
    required this.urgentSurcharge,
    required this.billableKm,
    required this.distanceSurcharge,
    required this.discount,
    required this.servicePrice,
    required this.platformFee,
    required this.foundationShare,
    required this.vetPayout,
    required this.extraDonation,
    required this.total,
    required this.foundationName,
    required this.expiresAt,
    this.distanceKm,
    this.maxServicePrice,
    this.maxTotal,
    this.maxDistanceKm,
    this.planName,
    this.isPreventive = false,
    this.planSubsidy = 0,
  });

  factory fromJson(Map<String, dynamic> j) => Quote(
    id: j['quote_id'] as String,
    mode: VisitMode.parse(j['mode'] as String?),
    basePrice: j['base_price'] as int,
    urgentSurcharge: j['urgent_surcharge'] as int,
    billableKm: j['billable_km'] as int,
    distanceSurcharge: j['distance_surcharge'] as int,
    discount: j['discount'] as int,
    servicePrice: j['service_price'] as int,
    platformFee: j['platform_fee'] as int,
    foundationShare: j['foundation_share'] as int,
    vetPayout: j['vet_payout'] as int,
    extraDonation: j['extra_donation'] as int,
    total: j['total'] as int,
    foundationName: j['foundation_name'] as String? ?? 'Fundación',
    expiresAt: DateTime.parse(j['expires_at'] as String).toLocal(),
    distanceKm: (j['distance_km'] as num?)?.toDouble(),
    maxServicePrice: (j['max_service_price'] as num?)?.toInt(),
    maxTotal: (j['max_total'] as num?)?.toInt(),
    maxDistanceKm: (j['max_distance_km'] as num?)?.toDouble(),
    planName: switch (j['plan']) {
      final Map<dynamic, dynamic> p => p['name'] as String?,
      _ => null,
    },
    isPreventive: j['is_preventive'] as bool? ?? false,
    planSubsidy: (j['plan_subsidy'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final VisitMode mode;
  final int basePrice;
  final int urgentSurcharge;
  final int billableKm;
  final int distanceSurcharge;
  final int discount;
  final int servicePrice;
  final int platformFee;
  final int foundationShare;
  final int vetPayout;
  final int extraDonation;
  final int total;
  final String foundationName;
  final DateTime expiresAt;

  /// Distancia redondeada a 0,5 km; null mientras no hay vet asignado.
  final double? distanceKm;

  // Urgencia en búsqueda (fase 8): tope del servicio y del total si el vet
  // que acepte está a [maxDistanceKm]. El precio final se fija al aceptar.
  final int? maxServicePrice;
  final int? maxTotal;
  final double? maxDistanceKm;

  // Fase 10: plan aplicado (null sin plan), visita preventiva incluida y lo
  // que Felix cubre por el plan (el vet cobra la tarifa de lista).
  final String? planName;
  final bool isPreventive;
  final int planSubsidy;

  /// La distancia solo se conoce cuando hay un vet (fase 6 / 8).
  bool get distancePending => distanceKm == null;
}

@immutable
class Foundation {
  const new({
    required this.id,
    required this.name,
    required this.active,
    required this.isDefault,
    this.description,
    this.website,
  });

  final String id;
  final String name;
  final String? description;
  final String? website;
  final bool active;
  final bool isDefault;
}

/// Datos que el admin edita de una fundación.
@immutable
class FoundationDraft {
  const new({required this.name, this.description, this.website});

  final String name;
  final String? description;
  final String? website;

  Map<String, Object?> toRow() => {
    'name': name.trim(),
    'description': _blank(description),
    'website': _blank(website),
  };

  static String? _blank(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();
}

/// Totales de un mes para el panel de la fundación (solo agregados).
@immutable
class FoundationMonth {
  const new({
    required this.month,
    required this.commissionTotal,
    required this.donationTotal,
    required this.total,
  });

  final DateTime month;
  final int commissionTotal;
  final int donationTotal;
  final int total;
}

const _months = [
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

/// "noviembre 2026".
String monthLabel(DateTime m) => '${_months[m.month - 1]} ${m.year}';

/// Valida la donación extra (texto con o sin puntos de miles).
String? validateDonation(String? v) {
  final raw = (v ?? '').replaceAll('.', '').trim();
  if (raw.isEmpty) return null;
  final n = int.tryParse(raw);
  if (n == null || n < 0) return 'Ingresa un monto en pesos';
  if (n > 1000000) return r'El máximo es $1.000.000';
  return null;
}

int parseDonation(String? v) =>
    int.tryParse((v ?? '').replaceAll('.', '').trim()) ?? 0;
