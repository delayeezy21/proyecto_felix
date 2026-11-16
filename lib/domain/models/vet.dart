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

/// Solicitud pendiente en la cola del admin.
@immutable
class VetApplicationSummary {
  const new({
    required this.userId,
    required this.displayName,
    required this.submittedAt,
    this.university,
  });

  final String userId;
  final String displayName;
  final String? university;
  final DateTime submittedAt;
}

/// Detalle completo de una solicitud para revisar.
@immutable
class VetApplicationDetail {
  const new({
    required this.profile,
    required this.documents,
    required this.speciesNames,
    required this.specialtyNames,
  });

  final VetProfile profile;
  final List<VetDocument> documents;
  final List<String> speciesNames;
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
