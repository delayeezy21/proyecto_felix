import 'package:flutter/foundation.dart' show immutable;
import 'package:proyecto_felix/domain/models/account.dart';

/// Documentos de verificación (en Chile no hay registro público de vets).
enum VetDocumentKind {
  degreeCertificate(
    'degree_certificate',
    'Certificado de título',
    required: true,
  ),
  idCardFront('id_card_front', 'Cédula de identidad (anverso)', required: true),
  colmevet('colmevet', 'Certificado COLMEVET (opcional)', required: false);

  new(this.dbValue, this.label, {required this.required});

  final String dbValue;
  final String label;
  final bool required;

  static VetDocumentKind? tryParse(String? v) {
    for (final k in values) {
      if (k.dbValue == v) return k;
    }
    return null;
  }
}

@immutable
class VetDocument {
  const new({
    required this.id,
    required this.kind,
    required this.mime,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.reviewStatus,
    this.storagePath,
    this.purgedAt,
  });

  final String id;
  final VetDocumentKind kind;
  final String mime;
  final int sizeBytes;
  final DateTime uploadedAt;
  final String reviewStatus;

  /// null cuando ya fue purgado.
  final String? storagePath;
  final DateTime? purgedAt;

  bool get isPurged => purgedAt != null;
}

/// Bloque semanal de disponibilidad (minutos desde las 00:00, 1 = lunes).
@immutable
class AvailabilityBlock {
  const new({
    required this.id,
    required this.weekday,
    required this.startMin,
    required this.endMin,
  });

  final String id;
  final int weekday;
  final int startMin;
  final int endMin;
}

@immutable
class VetProfile {
  const new({
    required this.userId,
    required this.displayName,
    required this.status,
    this.bio,
    this.university,
    this.graduationYear,
    this.foreignDegree = false,
    this.titleVerificationCode,
    this.declarationAcceptedAt,
    this.submittedAt,
    this.reviewedAt,
    this.rejectionReason,
    this.reviewNotes,
  });

  final String userId;
  final String displayName;
  final VetStatus status;
  final String? bio;
  final String? university;
  final int? graduationYear;
  final bool foreignDegree;
  final String? titleVerificationCode;
  final DateTime? declarationAcceptedAt;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final String? rejectionReason;
  final String? reviewNotes;

  bool get inReview => status == VetStatus.pending && submittedAt != null;

  /// Datos profesionales editables solo antes de enviar (o tras un rechazo).
  bool get canEditProfessionalData =>
      submittedAt == null &&
      (status == VetStatus.pending || status == VetStatus.rejected);
}

/// Veterinario en la lista del admin (pendiente o ya revisado).
@immutable
class VetApplicationSummary {
  const new({
    required this.userId,
    required this.displayName,
    required this.submittedAt,
    this.university,
    this.status = VetStatus.pending,
  });

  final String userId;
  final String displayName;
  final String? university;

  /// Puede faltar en perfiles que nunca enviaron la solicitud.
  final DateTime? submittedAt;
  final VetStatus status;
}

/// Detalle completo de una solicitud para revisar.
@immutable
class VetApplicationDetail {
  const new({
    required this.profile,
    required this.documents,
    required this.speciesNames,
    required this.specialtyNames,
    this.verifications = const [],
  });

  final VetProfile profile;
  final List<VetDocument> documents;
  final List<String> speciesNames;

  /// Último resultado de cada fuente de la verificación asistida (ronda
  /// actual). Vacío si está apagada, falló o aún no corre.
  final List<TitleVerification> verifications;
  final List<String> specialtyNames;
}

/// Archivo elegido por el usuario, listo para subir.
@immutable
class PickedDocument {
  const new({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// MIME según la extensión (el bucket acepta solo PDF, JPG y PNG).
  String? get mime => switch (extension) {
    'pdf' => 'application/pdf',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    _ => null,
  };
}

/// Fuente de una verificación asistida del título
/// (docs/verificacion-automatica.md).
enum VerificationSource {
  rules('rules', 'Reglas internas'),
  colmevet('colmevet', 'Buscador COLMEVET'),
  fake('fake', 'Proveedor de prueba');

  new(this.dbValue, this.label);

  final String dbValue;
  final String label;

  static VerificationSource? tryParse(String? v) {
    for (final s in values) {
      if (s.dbValue == v) return s;
    }
    return null;
  }
}

enum VerificationOutcome {
  match('match'),
  noMatch('no_match'),
  ambiguous('ambiguous'),
  error('error'),
  skipped('skipped');

  new(this.dbValue);

  final String dbValue;

  static VerificationOutcome parse(String? v) => values.firstWhere(
    (o) => o.dbValue == v,
    orElse: () => VerificationOutcome.error,
  );
}

enum VerificationRisk {
  low('low', 'Riesgo bajo'),
  medium('medium', 'Riesgo medio'),
  high('high', 'Riesgo alto');

  new(this.dbValue, this.label);

  final String dbValue;
  final String label;

  static VerificationRisk? tryParse(String? v) {
    for (final r in values) {
      if (r.dbValue == v) return r;
    }
    return null;
  }
}

/// Resultado de un proveedor de verificación. Solo sugiere chequeos: el admin
/// decide siempre (no hay auto-aprobación).
@immutable
class TitleVerification {
  const new({
    required this.source,
    required this.outcome,
    required this.createdAt,
    this.risk,
    this.suggestedChecks = const {},
  });

  final VerificationSource source;
  final VerificationOutcome outcome;
  final VerificationRisk? risk;

  /// Claves de la lista de chequeo del admin ('university', 'colmevet').
  final Set<String> suggestedChecks;
  final DateTime createdAt;

  /// Texto del resultado según la fuente.
  String get outcomeLabel => switch ((source, outcome)) {
    (VerificationSource.rules, VerificationOutcome.match) =>
      'Universidad en la lista de escuelas reconocidas',
    (VerificationSource.rules, VerificationOutcome.noMatch) =>
      'Universidad fuera de la lista: revísala manualmente',
    (_, VerificationOutcome.match) =>
      'Aparece como colegiado (una coincidencia)',
    (_, VerificationOutcome.noMatch) =>
      'Sin coincidencias (la colegiatura es voluntaria: no es una alerta)',
    (_, VerificationOutcome.ambiguous) =>
      'Varias coincidencias por nombre: revisa manualmente',
    (_, VerificationOutcome.skipped) =>
      'No se consultó (límite o nombre corto)',
    (_, VerificationOutcome.error) =>
      'No se pudo consultar: sigue con la revisión manual',
  };

  /// Línea breve para las notas de la revisión (queda en la auditoría).
  String get summary =>
      '${source.label}: ${outcome.dbValue}'
      '${risk == null ? '' : ' (${risk!.label.toLowerCase()})'}';
}

/// Último resultado de cada fuente, solo de la ronda actual (desde el envío).
List<TitleVerification> latestVerifications(
  Iterable<TitleVerification> all, {
  DateTime? since,
}) {
  final bySource = <VerificationSource, TitleVerification>{};
  for (final v in all) {
    if (since != null && v.createdAt.isBefore(since)) continue;
    final current = bySource[v.source];
    if (current == null || v.createdAt.isAfter(current.createdAt)) {
      bySource[v.source] = v;
    }
  }
  return [for (final s in VerificationSource.values) ?bySource[s]];
}

const int maxDocumentBytes = 5 * 1024 * 1024;

/// Valida un documento antes de subirlo (igual que el bucket).
String? validateDocument(PickedDocument file) {
  if (file.mime == null) return 'Solo se aceptan archivos PDF, JPG o PNG.';
  if (file.bytes.isEmpty) return 'El archivo está vacío.';
  if (file.bytes.length > maxDocumentBytes) {
    return 'El archivo supera los 5 MB.';
  }
  return null;
}

/// "09:30" a partir de minutos desde la medianoche.
String formatMinutes(int minutes) {
  final h = (minutes ~/ 60).toString().padLeft(2, '0');
  final m = (minutes % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

const weekdayNames = [
  'Lunes',
  'Martes',
  'Miércoles',
  'Jueves',
  'Viernes',
  'Sábado',
  'Domingo',
];
