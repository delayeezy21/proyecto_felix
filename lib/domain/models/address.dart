import 'package:flutter/foundation.dart' show immutable;
import 'package:proyecto_felix/domain/models/geo.dart';

/// Dirección del dueño. La exacta solo la ve su dueño (y, desde la fase 6,
/// el vet asignado mientras la visita está activa).
@immutable
class Address {
  const new({
    required this.id,
    required this.label,
    required this.streetText,
    required this.communeId,
    required this.point,
    required this.active,
    this.communeName,
    this.regionId,
    this.details,
  });

  final String id;
  final String label;
  final String streetText;
  final String? details;
  final int communeId;
  final String? communeName;
  final int? regionId;
  final GeoPoint point;
  final bool active;

  AddressDraft toDraft() => AddressDraft(
    label: label,
    streetText: streetText,
    details: details,
    communeId: communeId,
    point: point,
  );
}

/// Comuna compatible con un punto del mapa (la valida el servidor).
@immutable
class CommuneMatch {
  const new({
    required this.communeId,
    required this.regionId,
    required this.name,
    required this.distanceMeters,
  });

  final int communeId;
  final int regionId;
  final String name;

  /// 0 si el punto cae dentro del límite (ampliado) de la comuna.
  final double distanceMeters;
}

@immutable
class AddressDraft {
  const new({
    required this.label,
    required this.streetText,
    required this.communeId,
    required this.point,
    this.details,
  });

  final String label;
  final String streetText;
  final String? details;
  final int communeId;
  final GeoPoint point;

  Map<String, Object?> toRow() => {
    'label': label.trim(),
    'street_text': streetText.trim(),
    'details': (details ?? '').trim().isEmpty ? null : details!.trim(),
    'commune_id': communeId,
    'lat': point.lat,
    'lng': point.lng,
  };
}
