import 'package:flutter/foundation.dart' show immutable;

enum PetSex {
  male('male', 'Macho'),
  female('female', 'Hembra'),
  unknown('unknown', 'No sé');

  new(this.value, this.label);

  final String value;
  final String label;

  static PetSex parse(String? value) => PetSex.values.firstWhere(
    (s) => s.value == value,
    orElse: () => PetSex.unknown,
  );
}

@immutable
class Breed {
  const new({required this.id, required this.speciesId, required this.name});

  final int id;
  final int speciesId;
  final String name;
}

/// Mascota del dueño (lectura).
@immutable
class Pet {
  const new({
    required this.id,
    required this.name,
    required this.speciesId,
    required this.sex,
    required this.sterilized,
    required this.active,
    this.speciesName,
    this.breedId,
    this.breedName,
    this.birthDateApprox,
    this.microchip,
  });

  final String id;
  final String name;
  final int speciesId;

  /// null si la especie fue desactivada en el catálogo (la RLS la oculta).
  final String? speciesName;
  final int? breedId;
  final String? breedName;
  final PetSex sex;
  final DateTime? birthDateApprox;
  final bool sterilized;
  final String? microchip;
  final bool active;

  PetDraft toDraft() => PetDraft(
    name: name,
    speciesId: speciesId,
    breedId: breedId,
    sex: sex,
    birthDateApprox: birthDateApprox,
    sterilized: sterilized,
    microchip: microchip,
  );
}

/// Datos editables de una mascota.
@immutable
class PetDraft {
  const new({
    required this.name,
    required this.speciesId,
    this.breedId,
    this.sex = PetSex.unknown,
    this.birthDateApprox,
    this.sterilized = false,
    this.microchip,
  });

  final String name;
  final int speciesId;
  final int? breedId;
  final PetSex sex;
  final DateTime? birthDateApprox;
  final bool sterilized;
  final String? microchip;

  /// Columnas que acepta la BD (privilegio por columna).
  Map<String, Object?> toRow() => {
    'name': name.trim(),
    'species_id': speciesId,
    'breed_id': breedId,
    'sex': sex.value,
    'birth_date_approx': birthDateApprox == null
        ? null
        : formatIsoDate(birthDateApprox!),
    'sterilized': sterilized,
    'microchip': (microchip ?? '').trim().isEmpty ? null : microchip!.trim(),
  };
}

String formatIsoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Edad legible a partir de una fecha aproximada: "3 años", "5 meses".
String approxAge(DateTime birth, DateTime now) {
  var months = (now.year - birth.year) * 12 + now.month - birth.month;
  if (now.day < birth.day) months--;
  if (months < 0) return 'Recién nacido';
  if (months < 12) {
    if (months == 0) return 'Menos de 1 mes';
    return months == 1 ? '1 mes' : '$months meses';
  }
  final years = months ~/ 12;
  return years == 1 ? '1 año' : '$years años';
}

/// Microchip ISO 11784/11785: 15 dígitos (SPEC §7). Vacío = sin microchip.
String? validateMicrochip(String? value) {
  final v = (value ?? '').replaceAll(' ', '');
  if (v.isEmpty) return null;
  if (!RegExp(r'^\d{15}$').hasMatch(v)) {
    return 'El microchip tiene 15 dígitos.';
  }
  return null;
}
