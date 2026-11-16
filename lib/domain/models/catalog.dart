import 'package:flutter/foundation.dart' show immutable;

@immutable
class Region {
  const new({required this.id, required this.name});

  final int id;
  final String name;

  @override
  bool operator ==(Object other) => other is Region && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

@immutable
class Commune {
  const new({required this.id, required this.regionId, required this.name});

  final int id;
  final int regionId;
  final String name;

  @override
  bool operator ==(Object other) => other is Commune && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Catálogos simples administrables (nombre + activo).
enum CatalogKind {
  species('species', 'Especies', 'especie'),
  specialties('specialties', 'Especialidades', 'especialidad');

  new(this.table, this.title, this.singular);

  final String table;
  final String title;
  final String singular;
}

@immutable
class CatalogItem {
  const new({
    required this.id,
    required this.slug,
    required this.name,
    required this.active,
  });

  final int id;
  final String slug;
  final String name;
  final bool active;
}

@immutable
class Tariff {
  const new({
    required this.id,
    required this.specialtyName,
    required this.basePrice,
    required this.active,
    this.speciesName,
  });

  final int id;
  final String specialtyName;

  /// null = vale para todas las especies.
  final String? speciesName;
  final int basePrice;
  final bool active;
}

/// Parámetros económicos (una versión de `pricing_config`).
@immutable
class PricingConfig {
  const new({
    required this.commissionPct,
    required this.foundationPct,
    required this.urgentPct,
    required this.perKm,
    required this.freeKm,
    required this.cancelFee,
    this.effectiveFrom,
  });

  final double commissionPct;
  final double foundationPct;
  final double urgentPct;
  final int perKm;
  final int freeKm;
  final int cancelFee;
  final DateTime? effectiveFrom;
}

@immutable
class EmergencyClinic {
  const new({
    required this.id,
    required this.name,
    required this.communeId,
    required this.communeName,
    required this.address,
    required this.phone,
    required this.active,
  });

  final String id;
  final String name;
  final int communeId;
  final String communeName;
  final String address;
  final String phone;
  final bool active;
}

/// Convierte un nombre en slug: "Hurón Doméstico" → "huron_domestico".
String slugify(String name) {
  const from = 'áéíóúüñ';
  const to = 'aeiouun';
  final lower = name.trim().toLowerCase();
  final buffer = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i] : ch);
  }
  return buffer
      .toString()
      .replaceAll(RegExp('[^a-z]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}

/// Formatea pesos chilenos: 25000 → "$25.000".
String formatClp(int amount) {
  final digits = amount.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}\$$buffer';
}
