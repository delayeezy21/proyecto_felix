import 'dart:typed_data';

import 'package:proyecto_felix/domain/models/clinical.dart';
import 'package:proyecto_felix/domain/models/vet.dart'
    show PickedDocument, validateDocument;
import 'package:proyecto_felix/domain/models/visit.dart' show isoDate;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error legible de la ficha clínica.
class ClinicalFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'ClinicalFailure: $message';
}

/// Ficha clínica. Toda regla de acceso la aplica el servidor: el vet solo lee
/// con `get_pet_record` (cada lectura queda registrada) y los adjuntos se
/// descargan con una URL firmada de 60 s.
abstract interface class ClinicalRepository {
  /// [visitId]: visita del vet (para saber si puede escribir en ella).
  Future<PetRecord> record(String petId, {String? visitId});

  /// Agrega una entrada (o corrección). Devuelve su id.
  Future<String> addEntry(EntryDraft draft);

  Future<void> attach({
    required String petId,
    required String entryId,
    required PickedDocument file,
  });

  /// URL firmada (60 s) para abrir un adjunto.
  Future<Uri> attachmentUrl(String attachmentId);

  /// "Quién vio mi ficha" (solo el dueño).
  Future<List<AccessLogItem>> accessLog(String petId);

  Future<void> grantAccess({
    required String petId,
    required String vetId,
    required DateTime until,
  });

  Future<void> revokeGrant(String grantId);
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on ClinicalFailure {
    rethrow;
  } on PostgrestException catch (e) {
    throw ClinicalFailure(switch (e.code) {
      '22023' => e.message,
      '42501' when e.message.startsWith('La ficha no existe') => e.message,
      '42501' => 'No tienes acceso a esta ficha.',
      _ => 'No se pudo completar la acción. Inténtalo de nuevo.',
    });
  } on StorageException {
    throw const ClinicalFailure('No se pudo subir el archivo.');
  } on FunctionException {
    throw const ClinicalFailure(
      'El adjunto no está disponible o ya no tienes acceso.',
    );
  }
}

class SupabaseClinicalRepository implements ClinicalRepository {
  new(this._client);

  final SupabaseClient _client;

  static const bucket = 'clinical-attachments';
  static const signFunction = 'clinical-attachment-url';

  @override
  Future<PetRecord> record(String petId, {String? visitId}) => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'get_pet_record',
      params: {'p_pet_id': petId, 'p_visit_id': visitId},
    );
    return PetRecord.fromJson(json);
  });

  @override
  Future<String> addEntry(EntryDraft d) => _guard(() async {
    final error = validateEntryDraft(d);
    if (error != null) throw ClinicalFailure(error);
    final v = d.vaccine;
    return await _client.rpc<String>(
      'add_clinical_entry',
      params: {
        'p_pet_id': d.petId,
        'p_kind': d.kind.wire,
        'p_title': d.title.trim(),
        'p_body': (d.body ?? '').trim().isEmpty ? null : d.body!.trim(),
        'p_visit_id': d.visitId,
        'p_specialty_id': d.specialtyId,
        'p_supersedes_id': d.supersedesId,
        'p_vaccine': v == null
            ? null
            : {
                'vaccine_name': v.name.trim(),
                'lot': v.lot,
                'applied_on': isoDate(v.appliedOn),
                'next_due': v.nextDue == null ? null : isoDate(v.nextDue!),
              },
      },
    );
  });

  @override
  Future<void> attach({
    required String petId,
    required String entryId,
    required PickedDocument file,
  }) => _guard(() async {
    final error = validateDocument(file);
    if (error != null) throw ClinicalFailure(error);
    final path =
        'pets/$petId/$entryId/'
        '${DateTime.now().millisecondsSinceEpoch}.${file.extension}';
    await _client.storage
        .from(bucket)
        .uploadBinary(
          path,
          Uint8List.fromList(file.bytes),
          fileOptions: FileOptions(contentType: file.mime),
        );
    // Sin `select`: el vet no lee la tabla (solo inserta).
    await _client.from('entry_attachments').insert({
      'entry_id': entryId,
      'storage_path': path,
      'file_name': attachmentDisplayName(file.name),
      'mime': file.mime,
      'size_bytes': file.bytes.length,
    });
  });

  @override
  Future<Uri> attachmentUrl(String attachmentId) => _guard(() async {
    final res = await _client.functions.invoke(
      signFunction,
      body: {'attachment_id': attachmentId},
    );
    final data = res.data;
    final path = data is Map ? data['signed_path'] as String? : null;
    if (path == null) {
      throw const ClinicalFailure('El adjunto no está disponible.');
    }
    final rest = Uri.parse(_client.rest.url);
    return rest.replace(path: '', query: '').resolve(path);
  });

  @override
  Future<List<AccessLogItem>> accessLog(String petId) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'pet_access_log',
      params: {'p_pet_id': petId, 'p_limit': 200},
    );
    return [
      for (final r in rows)
        AccessLogItem.fromJson((r as Map).cast<String, dynamic>()),
    ];
  });

  @override
  Future<void> grantAccess({
    required String petId,
    required String vetId,
    required DateTime until,
  }) => _guard(
    () => _client.from('record_access_grants').insert({
      'pet_id': petId,
      'vet_id': vetId,
      'source': 'owner',
      'expires_at': until.toUtc().toIso8601String(),
    }),
  );

  @override
  Future<void> revokeGrant(String grantId) => _guard(
    () => _client
        .from('record_access_grants')
        .update({'revoked_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', grantId),
  );
}

/// Nombre visible del adjunto: sin rutas y de hasta 120 caracteres.
String attachmentDisplayName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  final safe = base.isEmpty ? 'adjunto' : base;
  return safe.length <= 120 ? safe : safe.substring(safe.length - 120);
}
