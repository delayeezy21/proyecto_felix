import 'dart:convert';
import 'dart:typed_data';

import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';

final marketingPurpose = ConsentPurpose(
  purpose: 'marketing',
  description: 'Novedades, promociones y encuestas de Felix.',
  granted: true,
  grantedAt: DateTime(2026, 11, 2),
);

/// Privacidad en memoria (fase 11). Simula el bloqueo del servidor: con una
/// solicitud `blocked`, todo salvo exportar y el borrado lanza
/// [AccountBlockedException].
class FakePrivacyRepository implements PrivacyRepository {
  new({
    this.privacyVersion = 'p-1',
    this.mustReview = false,
    List<ConsentPurpose>? purposes,
    this.deletion,
    List<RetainedEntry>? retained,
  }) : purposes = purposes ?? [marketingPurpose],
       retained = retained ?? [];

  String privacyVersion;
  bool mustReview;
  List<ConsentPurpose> purposes;
  DeletionRequest? deletion;
  List<RetainedEntry> retained;

  final consentCalls = <(String, bool)>[];
  final retainedRequests = <(String, String)>[];
  int exportCalls = 0;
  int noticeViews = 0;
  int cancelCalls = 0;
  int requestCalls = 0;

  /// Si se define, la próxima operación falla con este error.
  Exception? nextFailure;

  /// Fecha que el servidor fijaría como fin de la gracia.
  DateTime executeAfter = DateTime(2026, 12, 10, 14, 5);

  bool get _blocked => deletion?.status == DeletionStatus.blocked;

  void _maybeFail({bool allowBlocked = false}) {
    final failure = nextFailure;
    if (failure != null) {
      nextFailure = null;
      throw failure;
    }
    if (_blocked && !allowBlocked) throw const AccountBlockedException();
  }

  PrivacyStatus get _status => PrivacyStatus(
    privacyVersion: privacyVersion,
    lastSeenVersion: mustReview ? 'p-0' : privacyVersion,
    mustReview: mustReview,
    purposes: purposes,
  );

  @override
  Future<Map<String, dynamic>> exportMyData() async {
    exportCalls++;
    _maybeFail(allowBlocked: true);
    return {
      'format': 'felix-export',
      'format_version': 1,
      'subject_role': 'owner',
      'account': {'email': 'ana@ejemplo.cl'},
    };
  }

  @override
  Future<PrivacyStatus> status() async {
    _maybeFail();
    return _status;
  }

  @override
  Future<PrivacyStatus> setConsent(
    String purpose, {
    required bool granted,
  }) async {
    consentCalls.add((purpose, granted));
    _maybeFail();
    if (!purposes.any((p) => p.purpose == purpose)) {
      throw const PrivacyFailure('Finalidad opcional desconocida');
    }
    purposes = [
      for (final p in purposes)
        if (p.purpose == purpose)
          ConsentPurpose(
            purpose: p.purpose,
            description: p.description,
            granted: granted,
            grantedAt: granted ? DateTime(2026, 11, 25) : null,
            lastRevokedAt: granted ? p.lastRevokedAt : DateTime(2026, 11, 25),
          )
        else
          p,
    ];
    return _status;
  }

  @override
  Future<PrivacyStatus> recordNoticeView() async {
    noticeViews++;
    _maybeFail();
    mustReview = false;
    return _status;
  }

  @override
  Future<DeletionRequest> requestDeletion() async {
    requestCalls++;
    _maybeFail(allowBlocked: true);
    return deletion ??= DeletionRequest(
      id: 'd1',
      status: DeletionStatus.blocked,
      requestedAt: DateTime(2026, 11, 25, 14, 5),
      executeAfter: executeAfter,
      cancellable: true,
    );
  }

  @override
  Future<DeletionRequest> cancelDeletion() async {
    cancelCalls++;
    _maybeFail(allowBlocked: true);
    final d = deletion;
    if (d == null || !d.cancellable) {
      throw const PrivacyFailure(
        'El período de gracia terminó: la eliminación ya está en curso',
      );
    }
    return deletion = DeletionRequest(
      id: d.id,
      status: DeletionStatus.cancelled,
      requestedAt: d.requestedAt,
      executeAfter: d.executeAfter,
      cancelledAt: DateTime(2026, 11, 26),
      cancellable: false,
    );
  }

  @override
  Future<DeletionRequest?> myDeletionRequest() async {
    _maybeFail(allowBlocked: true);
    return deletion;
  }

  @override
  Future<List<RetainedEntry>> retainedEntries() async {
    _maybeFail();
    return retained;
  }

  @override
  Future<RetainedEntryDetail> requestRetainedEntry(
    String entryId, {
    required String reason,
  }) async {
    retainedRequests.add((entryId, reason));
    _maybeFail();
    final e = retained.firstWhere((r) => r.id == entryId);
    return RetainedEntryDetail(
      id: e.id,
      createdAt: e.createdAt,
      kind: e.kind,
      title: 'Control anual',
      body: 'Paciente [redactado] sin hallazgos.',
      species: e.species,
      retainUntil: e.retainUntil,
    );
  }
}

/// Guardado de archivos en memoria.
class FakeFileSaver implements FileSaver {
  final saved = <(String, String)>[];

  /// false simula que el usuario canceló el diálogo.
  bool result = true;

  String get lastJson => saved.last.$2;

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    saved.add((fileName, utf8.decode(bytes)));
    return result;
  }
}
