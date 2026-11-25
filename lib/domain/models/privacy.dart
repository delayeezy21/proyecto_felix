import 'package:flutter/foundation.dart' show immutable;

/// Derechos de privacidad (fase 11, Ley 21.719; docs/arquitectura.md §8.2).

DateTime? _date(Object? v) =>
    v == null ? null : DateTime.parse(v as String).toLocal();

/// Finalidad opcional (hoy solo `marketing`) y su estado para el usuario.
@immutable
class ConsentPurpose {
  const new({
    required this.purpose,
    required this.description,
    required this.granted,
    this.grantedAt,
    this.lastRevokedAt,
    this.ask = false,
  });

  factory fromJson(Map<String, dynamic> j) => ConsentPurpose(
    purpose: j['purpose'] as String,
    description: (j['description'] as String?) ?? '',
    granted: (j['granted'] as bool?) ?? false,
    grantedAt: _date(j['granted_at']),
    lastRevokedAt: _date(j['last_revoked_at']),
    ask: (j['ask'] as bool?) ?? false,
  );

  final String purpose;
  final String description;
  final bool granted;
  final DateTime? grantedAt;
  final DateTime? lastRevokedAt;

  /// Finalidad nueva (posterior al alta) que el usuario nunca respondió.
  final bool ask;

  /// Nombre legible de la finalidad.
  String get label => switch (purpose) {
    'marketing' => 'Novedades y comunicaciones',
    _ => purpose,
  };
}

/// Un otorgamiento (y su retiro, si lo hubo) del historial de consentimientos.
@immutable
class ConsentEvent {
  const new({
    required this.purpose,
    required this.grantedAt,
    this.version,
    this.revokedAt,
  });

  factory fromJson(Map<String, dynamic> j) => ConsentEvent(
    purpose: j['purpose'] as String,
    version: j['version'] as String?,
    grantedAt: _date(j['granted_at'])!,
    revokedAt: _date(j['revoked_at']),
  );

  final String purpose;
  final String? version;
  final DateTime grantedAt;
  final DateTime? revokedAt;
}

/// Respuesta de `my_privacy_status()` (también de `set_consent` y
/// `record_privacy_notice_view`).
@immutable
class PrivacyStatus {
  const new({
    required this.privacyVersion,
    required this.mustReview,
    required this.purposes,
    this.lastSeenVersion,
    this.termsVersion,
    this.history = const [],
  });

  factory fromJson(Map<String, dynamic> j) => PrivacyStatus(
    privacyVersion: (j['privacy_version'] as String?) ?? '',
    lastSeenVersion: j['last_seen_version'] as String?,
    mustReview: (j['must_review'] as bool?) ?? false,
    termsVersion: j['terms_version'] as String?,
    purposes: [
      for (final p in (j['purposes'] as List?) ?? const [])
        ConsentPurpose.fromJson((p as Map).cast<String, dynamic>()),
    ],
    history: [
      for (final h in (j['history'] as List?) ?? const [])
        ConsentEvent.fromJson((h as Map).cast<String, dynamic>()),
    ],
  );

  final String privacyVersion;
  final String? lastSeenVersion;

  /// La política vigente cambió desde la última vez que el usuario la vio.
  final bool mustReview;
  final String? termsVersion;
  final List<ConsentPurpose> purposes;
  final List<ConsentEvent> history;
}

/// Estado de una solicitud de eliminación de cuenta.
enum DeletionStatus {
  blocked,
  executing,
  done,
  cancelled;

  static DeletionStatus parse(String? v) => switch (v) {
    'executing' => DeletionStatus.executing,
    'done' => DeletionStatus.done,
    'cancelled' => DeletionStatus.cancelled,
    _ => DeletionStatus.blocked,
  };
}

/// Respuesta de `request_account_deletion`, `cancel_account_deletion` y
/// `my_deletion_request`.
@immutable
class DeletionRequest {
  const new({
    required this.id,
    required this.status,
    required this.requestedAt,
    required this.executeAfter,
    required this.cancellable,
    this.cancelledAt,
  });

  factory fromJson(Map<String, dynamic> j) => DeletionRequest(
    id: j['request_id'] as String,
    status: DeletionStatus.parse(j['status'] as String?),
    requestedAt: _date(j['requested_at'])!,
    executeAfter: _date(j['execute_after'])!,
    cancelledAt: _date(j['cancelled_at']),
    cancellable: (j['cancellable'] as bool?) ?? false,
  );

  final String id;
  final DeletionStatus status;
  final DateTime requestedAt;

  /// Desde esta fecha el borrado ya no se puede cancelar.
  final DateTime executeAfter;
  final DateTime? cancelledAt;
  final bool cancellable;

  /// La cuenta sigue bloqueada (en gracia o ejecutándose).
  bool get isActive =>
      status == DeletionStatus.blocked || status == DeletionStatus.executing;
}

/// Entrada clínica de la que el vet es autor, retenida (sin dueño) tras el
/// borrado de una cuenta. El listado no trae el contenido.
@immutable
class RetainedEntry {
  const new({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.retainUntil,
    this.species,
  });

  factory fromJson(Map<String, dynamic> j) => RetainedEntry(
    id: j['id'] as String,
    createdAt: _date(j['created_at'])!,
    kind: (j['kind'] as String?) ?? '',
    species: j['species'] as String?,
    retainUntil: _date(j['retain_until'])!,
  );

  final String id;
  final DateTime createdAt;
  final String kind;
  final String? species;
  final DateTime retainUntil;
}

/// Contenido (redactado) de una entrada retenida, tras una solicitud con
/// motivo.
@immutable
class RetainedEntryDetail {
  const new({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.body,
    required this.retainUntil,
    this.title,
    this.species,
    this.specialty,
    this.vaccineName,
    this.vaccineLot,
  });

  factory fromJson(Map<String, dynamic> j) {
    final vaccine = (j['vaccine'] as Map?)?.cast<String, dynamic>();
    return RetainedEntryDetail(
      id: j['id'] as String,
      createdAt: _date(j['created_at'])!,
      kind: (j['kind'] as String?) ?? '',
      title: j['title'] as String?,
      body: (j['body'] as String?) ?? '',
      species: j['species'] as String?,
      specialty: j['specialty'] as String?,
      retainUntil: _date(j['retain_until'])!,
      vaccineName: vaccine?['vaccine_name'] as String?,
      vaccineLot: vaccine?['lot'] as String?,
    );
  }

  final String id;
  final DateTime createdAt;
  final String kind;
  final String? title;
  final String body;
  final String? species;
  final String? specialty;
  final DateTime retainUntil;
  final String? vaccineName;
  final String? vaccineLot;
}

/// Motivo válido para consultar una entrada retenida (10 a 500 caracteres).
String? validateRetainedReason(String? value) {
  final n = (value ?? '').trim().length;
  if (n < 10) return 'Escribe el motivo (al menos 10 caracteres)';
  if (n > 500) return 'El motivo admite hasta 500 caracteres';
  return null;
}

/// Nombre del archivo de la exportación: `felix-mis-datos-AAAA-MM-DD.json`.
String exportFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'felix-mis-datos-${now.year.toString().padLeft(4, '0')}-'
      '${two(now.month)}-${two(now.day)}.json';
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

/// "9 de diciembre de 2026".
String formatLongDate(DateTime d) =>
    '${d.day} de ${_months[d.month - 1]} de ${d.year}';

/// "9 de diciembre de 2026, 14:05".
String formatLongDateTime(DateTime d) =>
    '${formatLongDate(d)}, ${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';
