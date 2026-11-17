import 'dart:async';
import 'dart:typed_data';

import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class VetFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'VetFailure: $message';
}

abstract interface class VetRepository {
  // --- Vet (su propia solicitud y perfil) ---
  Future<VetProfile> myProfile();

  Future<void> updateProfessionalData({
    required String? bio,
    required String? university,
    required int? graduationYear,
    required bool foreignDegree,
    required String? titleVerificationCode,
  });

  Future<void> updateBio(String? bio);

  Future<void> acceptDeclaration();

  Future<Set<int>> mySpeciesIds();

  Future<void> setSpecies(Set<int> ids);

  Future<Set<int>> mySpecialtyIds();

  Future<void> setSpecialties(Set<int> ids);

  Future<List<AvailabilityBlock>> myAvailability();

  Future<void> addAvailability(int weekday, int startMin, int endMin);

  Future<void> removeAvailability(String id);

  Future<List<VetDocument>> myDocuments();

  Future<void> uploadDocument(VetDocumentKind kind, PickedDocument file);

  Future<void> submitApplication();

  // --- Admin ---
  Future<List<VetApplicationSummary>> pendingApplications();

  Future<VetApplicationDetail> applicationDetail(String vetId);

  /// Enlace temporal (60 s) para ver un documento.
  Future<String> documentUrl(String storagePath);

  Future<void> review(
    String vetId, {
    required bool approve,
    String? reason,
    String? notes,
  });

  /// Ejecuta la verificación asistida del título (Edge Function
  /// `verify-vet-title`). Solo sugiere chequeos; nunca aprueba.
  Future<void> runTitleVerification(String vetId);
}

class SupabaseVetRepository implements VetRepository {
  new(this._client);

  final SupabaseClient _client;
  static const _bucket = 'vet-documents';
  static const _profileColumns =
      'user_id, display_name, status, bio, university, graduation_year, '
      'foreign_degree, title_verification_code, declaration_accepted_at, '
      'submitted_at, reviewed_at, rejection_reason, review_notes';

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw const VetFailure('Tu sesión expiró.');
    return id;
  }

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse(v as String);

  static VetProfile _profile(Map<String, dynamic> r) => VetProfile(
    userId: r['user_id'] as String,
    displayName: r['display_name'] as String,
    status: VetStatus.parse(r['status'] as String?),
    bio: r['bio'] as String?,
    university: r['university'] as String?,
    graduationYear: r['graduation_year'] as int?,
    foreignDegree: (r['foreign_degree'] as bool?) ?? false,
    titleVerificationCode: r['title_verification_code'] as String?,
    declarationAcceptedAt: _date(r['declaration_accepted_at']),
    submittedAt: _date(r['submitted_at']),
    reviewedAt: _date(r['reviewed_at']),
    rejectionReason: r['rejection_reason'] as String?,
    reviewNotes: r['review_notes'] as String?,
  );

  static VetDocument? _document(Map<String, dynamic> r) {
    final kind = VetDocumentKind.tryParse(r['kind'] as String?);
    if (kind == null) return null;
    return VetDocument(
      id: r['id'] as String,
      kind: kind,
      mime: r['mime'] as String,
      sizeBytes: r['size_bytes'] as int,
      uploadedAt: _date(r['uploaded_at'])!,
      reviewStatus: r['review_status'] as String,
      storagePath: r['storage_path'] as String?,
      purgedAt: _date(r['purged_at']),
    );
  }

  @override
  Future<VetProfile> myProfile() => _guard(() async {
    final r = await _client
        .from('vet_profiles')
        .select(_profileColumns)
        .eq('user_id', _uid)
        .single();
    return _profile(r);
  });

  @override
  Future<void> updateProfessionalData({
    required String? bio,
    required String? university,
    required int? graduationYear,
    required bool foreignDegree,
    required String? titleVerificationCode,
  }) => _guard(
    () => _client
        .from('vet_profiles')
        .update({
          'bio': _blank(bio),
          'university': _blank(university),
          'graduation_year': graduationYear,
          'foreign_degree': foreignDegree,
          'title_verification_code': _blank(titleVerificationCode),
        })
        .eq('user_id', _uid),
  );

  @override
  Future<void> updateBio(String? bio) => _guard(
    () => _client
        .from('vet_profiles')
        .update({'bio': _blank(bio)})
        .eq('user_id', _uid),
  );

  @override
  Future<void> acceptDeclaration() => _guard(
    () => _client
        .from('vet_profiles')
        .update({
          'declaration_accepted_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('user_id', _uid),
  );

  Future<Set<int>> _ids(String table, String column) => _guard(() async {
    final rows = await _client.from(table).select(column).eq('vet_id', _uid);
    return {for (final r in rows) r[column] as int};
  });

  Future<void> _setIds(String table, String column, Set<int> ids) =>
      _guard(() async {
        final current = await _ids(table, column);
        final toAdd = ids.difference(current);
        final toRemove = current.difference(ids);
        if (toRemove.isNotEmpty) {
          await _client
              .from(table)
              .delete()
              .eq('vet_id', _uid)
              .inFilter(column, toRemove.toList());
        }
        if (toAdd.isNotEmpty) {
          await _client.from(table).insert([
            for (final id in toAdd) {'vet_id': _uid, column: id},
          ]);
        }
      });

  @override
  Future<Set<int>> mySpeciesIds() => _ids('vet_species', 'species_id');

  @override
  Future<void> setSpecies(Set<int> ids) =>
      _setIds('vet_species', 'species_id', ids);

  @override
  Future<Set<int>> mySpecialtyIds() => _ids('vet_specialties', 'specialty_id');

  @override
  Future<void> setSpecialties(Set<int> ids) =>
      _setIds('vet_specialties', 'specialty_id', ids);

  @override
  Future<List<AvailabilityBlock>> myAvailability() => _guard(() async {
    final rows = await _client
        .from('vet_availability')
        .select('id, weekday, start_min, end_min')
        .eq('vet_id', _uid)
        .order('weekday')
        .order('start_min');
    return [
      for (final r in rows)
        AvailabilityBlock(
          id: r['id'] as String,
          weekday: r['weekday'] as int,
          startMin: r['start_min'] as int,
          endMin: r['end_min'] as int,
        ),
    ];
  });

  @override
  Future<void> addAvailability(int weekday, int startMin, int endMin) => _guard(
    () => _client.from('vet_availability').insert({
      'vet_id': _uid,
      'weekday': weekday,
      'start_min': startMin,
      'end_min': endMin,
    }),
  );

  @override
  Future<void> removeAvailability(String id) => _guard(
    () => _client
        .from('vet_availability')
        .delete()
        .eq('id', id)
        .eq('vet_id', _uid),
  );

  @override
  Future<List<VetDocument>> myDocuments() => _documentsOf(_uid);

  Future<List<VetDocument>> _documentsOf(String vetId) => _guard(() async {
    final rows = await _client
        .from('vet_documents')
        .select(
          'id, kind, mime, size_bytes, uploaded_at, review_status, '
          'storage_path, purged_at',
        )
        .eq('vet_id', vetId)
        .order('uploaded_at', ascending: false);
    return [for (final r in rows) ?_document(r)];
  });

  @override
  Future<void> uploadDocument(VetDocumentKind kind, PickedDocument file) =>
      _guard(() async {
        final error = validateDocument(file);
        if (error != null) throw VetFailure(error);
        final path =
            '$_uid/${kind.dbValue}-'
            '${DateTime.now().millisecondsSinceEpoch}.${file.extension}';
        await _client.storage
            .from(_bucket)
            .uploadBinary(
              path,
              Uint8List.fromList(file.bytes),
              fileOptions: FileOptions(contentType: file.mime),
            );
        // Si el registro falla, el archivo queda huérfano y la purga del
        // servidor lo borra pasadas 24 h (el vet no borra archivos; QA-06).
        await _client.from('vet_documents').insert({
          'vet_id': _uid,
          'kind': kind.dbValue,
          'storage_path': path,
          'mime': file.mime,
          'size_bytes': file.bytes.length,
        });
      });

  @override
  Future<void> submitApplication() async {
    await _guard(() => _client.rpc<dynamic>('submit_vet_application'));
    // Verificación asistida en segundo plano: si falla o está apagada, la
    // revisión manual sigue igual (el admin puede ejecutarla después).
    unawaited(
      _client.functions
          .invoke(verificationFunction, body: const <String, dynamic>{})
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  static const verificationFunction = 'verify-vet-title';

  static TitleVerification? _verification(Map<String, dynamic> r) {
    final source = VerificationSource.tryParse(r['source'] as String?);
    final at = _date(r['created_at']);
    if (source == null || at == null) return null;
    return TitleVerification(
      source: source,
      outcome: VerificationOutcome.parse(r['outcome'] as String?),
      risk: VerificationRisk.tryParse(r['risk'] as String?),
      suggestedChecks: {
        for (final c in (r['suggested_checks'] as List?) ?? const []) '$c',
      },
      createdAt: at,
    );
  }

  /// Resultados de la ronda actual. Si la consulta falla, lista vacía: la
  /// revisión manual no depende de la verificación automática.
  Future<List<TitleVerification>> _verificationsOf(
    String vetId,
    DateTime? since,
  ) async {
    try {
      final rows = await _client
          .from('vet_title_verifications')
          .select('source, outcome, risk, suggested_checks, created_at')
          .eq('vet_id', vetId)
          .order('created_at', ascending: false)
          .limit(20);
      return latestVerifications([
        for (final r in rows) ?_verification(r),
      ], since: since);
    } on Object {
      return const [];
    }
  }

  @override
  Future<void> runTitleVerification(String vetId) async {
    try {
      await _client.functions.invoke(
        verificationFunction,
        body: {'vet_id': vetId},
      );
    } on FunctionException catch (e) {
      throw VetFailure(switch (e.status) {
        429 => 'Ya se ejecutó varias veces. Espera unos minutos.',
        409 => 'La solicitud ya no está en revisión.',
        _ =>
          'La verificación automática no está disponible. '
              'Sigue con la revisión manual.',
      });
    } on Object {
      throw const VetFailure(
        'La verificación automática no está disponible. '
        'Sigue con la revisión manual.',
      );
    }
  }

  @override
  Future<List<VetApplicationSummary>> pendingApplications() => _guard(() async {
    final rows = await _client
        .from('vet_profiles')
        .select('user_id, display_name, university, submitted_at')
        .eq('status', 'pending')
        .not('submitted_at', 'is', null)
        .order('submitted_at');
    return [
      for (final r in rows)
        VetApplicationSummary(
          userId: r['user_id'] as String,
          displayName: r['display_name'] as String,
          university: r['university'] as String?,
          submittedAt: _date(r['submitted_at'])!,
        ),
    ];
  });

  @override
  Future<VetApplicationDetail> applicationDetail(String vetId) =>
      _guard(() async {
        final p = await _client
            .from('vet_profiles')
            .select(_profileColumns)
            .eq('user_id', vetId)
            .single();
        final species = await _client
            .from('vet_species')
            .select('species(name)')
            .eq('vet_id', vetId);
        final specialties = await _client
            .from('vet_specialties')
            .select('specialties(name)')
            .eq('vet_id', vetId);
        final profile = _profile(p);
        return VetApplicationDetail(
          verifications: await _verificationsOf(vetId, profile.submittedAt),
          profile: profile,
          documents: await _documentsOf(vetId),
          speciesNames: [
            for (final r in species) (r['species'] as Map)['name'] as String,
          ],
          specialtyNames: [
            for (final r in specialties)
              (r['specialties'] as Map)['name'] as String,
          ],
        );
      });

  @override
  Future<String> documentUrl(String storagePath) => _guard(
    () => _client.storage.from(_bucket).createSignedUrl(storagePath, 60),
  );

  @override
  Future<void> review(
    String vetId, {
    required bool approve,
    String? reason,
    String? notes,
  }) => _guard(
    () => _client.rpc<dynamic>(
      'review_vet_application',
      params: {
        'p_vet_id': vetId,
        'p_approve': approve,
        'p_reason': _blank(reason),
        'p_notes': _blank(notes),
      },
    ),
  );

  static String? _blank(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on VetFailure {
      rethrow;
    } on PostgrestException catch (e) {
      throw VetFailure(switch (e.code) {
        // Los mensajes de validación de la BD ya están en español.
        '22023' => e.message,
        '23P01' => 'Ese bloque se cruza con otro del mismo día.',
        '23505' => 'Ese dato ya estaba registrado.',
        '23514' => 'Algún valor está fuera de rango.',
        '42501' =>
          e.message.startsWith('Los datos profesionales') ||
                  e.message.startsWith('Solo un administrador')
              ? e.message
              : 'No tienes permiso para esta acción.',
        _ => 'No se pudo guardar. Inténtalo de nuevo.',
      });
    } on StorageException catch (e) {
      throw VetFailure(
        e.statusCode == '413' || e.message.contains('size')
            ? 'El archivo supera los 5 MB.'
            : 'No se pudo subir el archivo. Inténtalo de nuevo.',
      );
    }
  }
}
