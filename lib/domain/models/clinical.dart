import 'package:flutter/foundation.dart' show immutable;

/// Tipo de entrada de la ficha. El dueño solo agrega notas.
enum EntryKind {
  consultation('consultation', 'Atención'),
  diagnosis('diagnosis', 'Diagnóstico'),
  vaccine('vaccine', 'Vacuna'),
  note('note', 'Nota');

  new(this.wire, this.label);

  final String wire;
  final String label;

  static EntryKind parse(String? v) =>
      values.firstWhere((k) => k.wire == v, orElse: () => note);
}

/// Datos de una vacuna (van en una entrada de tipo vacuna).
@immutable
class VaccineData {
  const new({
    required this.name,
    required this.appliedOn,
    this.lot,
    this.nextDue,
  });

  factory fromJson(Map<String, dynamic> j) => VaccineData(
    name: j['vaccine_name'] as String,
    lot: j['lot'] as String?,
    appliedOn: DateTime.parse(j['applied_on'] as String),
    nextDue: j['next_due'] == null
        ? null
        : DateTime.parse(j['next_due'] as String),
  );

  final String name;
  final String? lot;
  final DateTime appliedOn;
  final DateTime? nextDue;
}

/// Adjunto de una entrada (el archivo se descarga con una URL firmada corta).
@immutable
class EntryAttachment {
  const new({
    required this.id,
    required this.fileName,
    required this.mime,
    required this.sizeBytes,
  });

  factory fromJson(Map<String, dynamic> j) => EntryAttachment(
    id: j['id'] as String,
    fileName: j['file_name'] as String,
    mime: j['mime'] as String,
    sizeBytes: (j['size_bytes'] as num).toInt(),
  );

  final String id;
  final String fileName;
  final String mime;
  final int sizeBytes;
}

/// Entrada de la ficha (solo inserción: una corrección es otra entrada).
@immutable
class ClinicalEntry {
  const new({
    required this.id,
    required this.kind,
    required this.title,
    required this.byOwner,
    required this.createdAt,
    this.body,
    this.authorName,
    this.mine = false,
    this.visitId,
    this.specialtyName,
    this.supersedesId,
    this.supersededBy,
    this.vaccine,
    this.attachments = const [],
  });

  factory fromJson(Map<String, dynamic> j) => ClinicalEntry(
    id: j['id'] as String,
    kind: EntryKind.parse(j['kind'] as String?),
    title: j['title'] as String,
    body: j['body'] as String?,
    byOwner: j['author_role'] == 'owner',
    authorName: j['author_name'] as String?,
    mine: j['mine'] as bool? ?? false,
    visitId: j['visit_id'] as String?,
    specialtyName: j['specialty_name'] as String?,
    createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
    supersedesId: j['supersedes_id'] as String?,
    supersededBy: j['superseded_by'] as String?,
    vaccine: j['vaccine'] is Map<String, dynamic>
        ? VaccineData.fromJson(j['vaccine'] as Map<String, dynamic>)
        : null,
    attachments: [
      for (final a in (j['attachments'] as List? ?? const []))
        EntryAttachment.fromJson((a as Map).cast<String, dynamic>()),
    ],
  );

  final String id;
  final EntryKind kind;
  final String title;
  final String? body;

  /// Aportada por el dueño (si no, la escribió un vet).
  final bool byOwner;
  final String? authorName;

  /// La escribió el usuario actual (puede corregirla).
  final bool mine;
  final String? visitId;
  final String? specialtyName;
  final DateTime createdAt;
  final String? supersedesId;
  final String? supersededBy;
  final VaccineData? vaccine;
  final List<EntryAttachment> attachments;

  bool get isCurrent => supersededBy == null;
}

/// Versión vigente de una entrada con sus versiones anteriores (de la más
/// reciente a la más antigua).
@immutable
class EntryHistory {
  const new(this.current, this.previous);

  final ClinicalEntry current;
  final List<ClinicalEntry> previous;

  bool get wasCorrected => previous.isNotEmpty;
}

/// Agrupa las entradas en cadenas de corrección (`supersedes_id`): devuelve
/// solo las vigentes, cada una con sus versiones anteriores, ordenadas por la
/// fecha de la versión vigente (más reciente primero). Una entrada cuya
/// anterior no llegó (p. ej., desvinculada) queda como inicio de su cadena.
List<EntryHistory> entryHistories(List<ClinicalEntry> entries) {
  final byId = {for (final e in entries) e.id: e};
  final replaced = {
    for (final e in entries)
      if (e.supersedesId != null) e.supersedesId!,
  };
  final histories = <EntryHistory>[];
  for (final e in entries) {
    if (replaced.contains(e.id)) continue;
    final previous = <ClinicalEntry>[];
    final seen = {e.id};
    var cursor = e.supersedesId;
    while (cursor != null && seen.add(cursor)) {
      final prev = byId[cursor];
      if (prev == null) break;
      previous.add(prev);
      cursor = prev.supersedesId;
    }
    histories.add(EntryHistory(e, previous));
  }
  histories.sort((a, b) => b.current.createdAt.compareTo(a.current.createdAt));
  return histories;
}

/// Autorización de acceso a la ficha (vista del dueño).
@immutable
class RecordGrant {
  const new({
    required this.id,
    required this.vetName,
    required this.fromVisit,
    required this.active,
    required this.startsAt,
    this.expiresAt,
    this.revokedAt,
  });

  factory fromJson(Map<String, dynamic> j) {
    DateTime? date(String k) =>
        j[k] == null ? null : DateTime.parse(j[k] as String).toLocal();
    return RecordGrant(
      id: j['id'] as String,
      vetName: j['vet_name'] as String? ?? 'Veterinario',
      fromVisit: j['source'] == 'visit',
      active: j['active'] as bool? ?? false,
      startsAt: date('starts_at')!,
      expiresAt: date('expires_at'),
      revokedAt: date('revoked_at'),
    );
  }

  final String id;
  final String vetName;

  /// Nació de una visita (no la revoca el dueño: vence sola).
  final bool fromVisit;
  final bool active;
  final DateTime startsAt;

  /// null = mientras la visita esté activa.
  final DateTime? expiresAt;
  final DateTime? revokedAt;

  bool get canRevoke => !fromVisit && active;
}

/// Mascota según la ficha.
@immutable
class RecordPet {
  const new({
    required this.id,
    required this.name,
    this.speciesName,
    this.breedName,
    this.microchip,
  });

  final String id;
  final String name;
  final String? speciesName;
  final String? breedName;
  final String? microchip;
}

/// Ficha completa (`get_pet_record`).
@immutable
class PetRecord {
  const new({
    required this.pet,
    required this.isOwnerView,
    required this.canWrite,
    required this.entries,
    this.grants = const [],
    this.accessVia,
    this.accessUntil,
  });

  factory fromJson(Map<String, dynamic> j) {
    final pet = (j['pet'] as Map).cast<String, dynamic>();
    final access = j['access'];
    return PetRecord(
      pet: RecordPet(
        id: pet['id'] as String,
        name: pet['name'] as String,
        speciesName: pet['species_name'] as String?,
        breedName: pet['breed_name'] as String?,
        microchip: pet['microchip'] as String?,
      ),
      isOwnerView: j['viewer'] == 'owner',
      canWrite: j['can_write'] as bool? ?? false,
      entries: [
        for (final e in (j['entries'] as List? ?? const []))
          ClinicalEntry.fromJson((e as Map).cast<String, dynamic>()),
      ],
      grants: [
        for (final g in (j['grants'] as List? ?? const []))
          RecordGrant.fromJson((g as Map).cast<String, dynamic>()),
      ],
      accessVia: access is Map ? access['via'] as String? : null,
      accessUntil: access is Map && access['until'] != null
          ? DateTime.parse(access['until'] as String).toLocal()
          : null,
    );
  }

  final RecordPet pet;
  final bool isOwnerView;
  final bool canWrite;
  final List<ClinicalEntry> entries;
  final List<RecordGrant> grants;

  /// Vet: 'visit' u 'owner_grant'.
  final String? accessVia;
  final DateTime? accessUntil;

  List<EntryHistory> get histories => entryHistories(entries);

  /// Vacunas vigentes (no reemplazadas), de la más reciente a la más antigua.
  List<ClinicalEntry> get vaccines => [
    for (final h in histories)
      if (h.current.vaccine != null) h.current,
  ];
}

/// Fila de "Quién vio mi ficha".
@immutable
class AccessLogItem {
  const new({
    required this.at,
    required this.action,
    required this.via,
    required this.actorName,
  });

  factory fromJson(Map<String, dynamic> j) => AccessLogItem(
    at: DateTime.parse(j['at'] as String).toLocal(),
    action: j['action'] as String,
    via: j['via'] as String,
    actorName: j['actor_name'] as String? ?? 'Sistema',
  );

  final DateTime at;
  final String action;
  final String via;
  final String actorName;

  String get actionLabel => switch (action) {
    'view' => 'vio la ficha',
    'download' => 'descargó un adjunto',
    'create' => 'agregó una entrada',
    'correct' => 'corrigió una entrada',
    'grant' => 'autorizó a un veterinario',
    'revoke' => 'revocó una autorización',
    'export' => 'exportó la ficha',
    _ => action,
  };

  String get viaLabel => switch (via) {
    'visit' => 'por una visita',
    'owner_grant' => 'con tu autorización',
    _ => '',
  };
}

/// Nueva entrada (o corrección de [supersedesId]).
@immutable
class EntryDraft {
  const new({
    required this.petId,
    required this.kind,
    required this.title,
    this.body,
    this.visitId,
    this.specialtyId,
    this.supersedesId,
    this.vaccine,
  });

  final String petId;
  final EntryKind kind;
  final String title;
  final String? body;
  final String? visitId;
  final int? specialtyId;
  final String? supersedesId;
  final VaccineData? vaccine;
}

/// Validación local (el servidor vuelve a validar todo).
String? validateEntryDraft(EntryDraft d) {
  final title = d.title.trim();
  if (title.isEmpty) return 'Escribe un título.';
  if (title.length > 120) return 'El título admite hasta 120 caracteres.';
  if ((d.body ?? '').length > 4000) {
    return 'El detalle admite hasta 4.000 caracteres.';
  }
  if (d.kind == EntryKind.vaccine) {
    final v = d.vaccine;
    if (v == null || v.name.trim().length < 2) {
      return 'Indica el nombre de la vacuna.';
    }
    if (v.nextDue != null && !v.nextDue!.isAfter(v.appliedOn)) {
      return 'La próxima dosis debe ser posterior a la aplicación.';
    }
  }
  return null;
}
