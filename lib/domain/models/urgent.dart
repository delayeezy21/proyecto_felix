import 'package:flutter/foundation.dart' show immutable;
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

/// Estado de la búsqueda de una urgencia (`urgent_search_status`). No trae
/// identidades de vets: solo el avance del despacho.
@immutable
class UrgentSearchStatus {
  const new({
    required this.visitId,
    required this.status,
    required this.searchUntil,
    required this.batches,
    required this.pendingOffers,
    this.radiusKm,
  });

  factory fromJson(Map<String, dynamic> j) => UrgentSearchStatus(
    visitId: j['visit_id'] as String,
    status: VisitStatus.parse(j['status'] as String?),
    searchUntil: DateTime.parse(j['search_until'] as String).toLocal(),
    radiusKm: (j['radius_km'] as num?)?.toDouble(),
    batches: (j['batches'] as num?)?.toInt() ?? 0,
    pendingOffers: (j['pending_offers'] as num?)?.toInt() ?? 0,
  );

  final String visitId;
  final VisitStatus status;

  /// Fin de la ventana de búsqueda (10 min desde la solicitud).
  final DateTime searchUntil;

  /// Radio de la última tanda (null = aún no sale la primera).
  final double? radiusKm;

  /// Tandas enviadas hasta ahora.
  final int batches;

  /// Vets que están viendo la oferta en este momento.
  final int pendingOffers;

  bool get isSearching => status == VisitStatus.searching;
}

/// Oferta de urgencia para el vet (`my_offers`). Nunca trae la dirección ni
/// coordenadas: solo comuna y distancia redondeada a 0,5 km.
@immutable
class UrgentOffer {
  const new({
    required this.offerId,
    required this.visitId,
    required this.batch,
    required this.createdAt,
    required this.expiresAt,
    required this.communeName,
    required this.distanceKm,
    required this.speciesName,
    required this.specialtyName,
    this.servicePrice,
    this.vetPayout,
  });

  factory fromJson(Map<String, dynamic> j) => UrgentOffer(
    offerId: j['offer_id'] as String,
    visitId: j['visit_id'] as String,
    batch: (j['batch'] as num).toInt(),
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
    expiresAt: DateTime.parse(j['expires_at'] as String).toLocal(),
    communeName: j['commune_name'] as String? ?? '',
    distanceKm: (j['distance_km'] as num?)?.toDouble() ?? 0,
    speciesName: j['species_name'] as String? ?? '',
    specialtyName: j['specialty_name'] as String? ?? '',
    servicePrice: (j['service_price'] as num?)?.toInt(),
    vetPayout: (j['vet_payout'] as num?)?.toInt(),
  );

  final String offerId;
  final String visitId;
  final int batch;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String communeName;
  final double distanceKm;
  final String speciesName;
  final String specialtyName;
  final int? servicePrice;
  final int? vetPayout;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
}

/// Por qué no se pudo aceptar una oferta (campo `hint` del error `22023`).
enum OfferFailureKind {
  taken('offer_taken', 'Otro vet ya tomó esta urgencia.'),
  expired('offer_expired', 'La oferta venció.'),
  closed('offer_closed', 'Esta urgencia ya no está disponible.');

  new(this.hint, this.message);

  final String hint;
  final String message;

  static OfferFailureKind? parse(String? hint) {
    for (final k in values) {
      if (k.hint == hint) return k;
    }
    return null;
  }
}

/// Posición del vet en camino (Realtime Broadcast `visit:{id}`). Solo
/// viaja en vivo: no se guarda el recorrido.
@immutable
class LiveLocation {
  const new(this.point, this.at);

  /// Acepta solo `{lat, lng, at}` con coordenadas válidas; ignora el resto.
  static LiveLocation? tryParse(Map<String, dynamic> m) {
    final lat = m['lat'];
    final lng = m['lng'];
    if (lat is! num || lng is! num) return null;
    final point = GeoPoint(lat.toDouble(), lng.toDouble());
    if (!point.isInChile) return null;
    final at = DateTime.tryParse(m['at'] as String? ?? '')?.toLocal();
    return LiveLocation(point, at ?? DateTime.now());
  }

  final GeoPoint point;
  final DateTime at;

  Map<String, Object> toPayload() => {
    'lat': point.lat,
    'lng': point.lng,
    'at': at.toUtc().toIso8601String(),
  };
}

/// "9:05" (minutos:segundos) hasta [until]; "0:00" si ya pasó.
String formatCountdown(DateTime until, DateTime now) {
  final left = until.difference(now);
  if (left.isNegative) return '0:00';
  final s = left.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
