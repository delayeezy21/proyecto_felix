import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

export 'package:proyecto_felix/data/services/account_blocked.dart'
    show AccountBlockedException;

class PrivacyFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'PrivacyFailure: $message';
}

/// Derechos de privacidad (fase 11, docs/arquitectura.md §8.2). Todas las
/// reglas (plazos, bloqueo, registro de cada acción) las aplica el servidor.
abstract interface class PrivacyRepository {
  /// Todos mis datos (`export_my_data`). El servidor registra la exportación.
  /// Funciona también con la cuenta bloqueada.
  Future<Map<String, dynamic>> exportMyData();

  Future<PrivacyStatus> status();

  /// Otorga o retira una finalidad opcional.
  Future<PrivacyStatus> setConsent(String purpose, {required bool granted});

  /// Registra que el usuario vio la política vigente.
  Future<PrivacyStatus> recordNoticeView();

  /// Pide borrar la cuenta: queda bloqueada de inmediato (idempotente).
  Future<DeletionRequest> requestDeletion();

  Future<DeletionRequest> cancelDeletion();

  /// La última solicitud, o null si no hay.
  Future<DeletionRequest?> myDeletionRequest();

  /// Vet: entradas de las que es autor, retenidas tras un borrado.
  Future<List<RetainedEntry>> retainedEntries();

  /// Vet: consulta una entrada retenida con un motivo (queda registrada).
  Future<RetainedEntryDetail> requestRetainedEntry(
    String entryId, {
    required String reason,
  });
}

/// Traduce los errores del servidor. `account_blocked` →
/// [AccountBlockedException]; 22023 trae el mensaje en español.
Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw mapPrivacyError(e);
  }
}

/// Excepción de dominio para un error de PostgREST de las RPC de privacidad.
Exception mapPrivacyError(PostgrestException e) {
  if (isAccountBlocked(e)) return const AccountBlockedException();
  return PrivacyFailure(switch (e.code) {
    // Las validaciones del servidor responden en español.
    '22023' => e.message,
    '42501' when e.message.startsWith('Esta cuenta') => e.message,
    '42501' => 'No tienes permiso para esta acción.',
    _ => 'No se pudo completar la acción. Inténtalo de nuevo.',
  });
}

Map<String, dynamic> _map(Object? v) => (v! as Map).cast<String, dynamic>();

class SupabasePrivacyRepository implements PrivacyRepository {
  new(this._client);

  final SupabaseClient _client;

  Future<PrivacyStatus> _statusRpc(String fn, [Map<String, dynamic>? params]) =>
      _guard(() async {
        final r = await _client.rpc<Object?>(fn, params: params);
        return PrivacyStatus.fromJson(_map(r));
      });

  Future<DeletionRequest?> _deletionRpc(String fn) => _guard(() async {
    final r = await _client.rpc<Object?>(fn);
    return r == null ? null : DeletionRequest.fromJson(_map(r));
  });

  @override
  Future<Map<String, dynamic>> exportMyData() =>
      _guard(() async => _map(await _client.rpc<Object?>('export_my_data')));

  @override
  Future<PrivacyStatus> status() => _statusRpc('my_privacy_status');

  @override
  Future<PrivacyStatus> setConsent(String purpose, {required bool granted}) =>
      _statusRpc('set_consent', {'p_purpose': purpose, 'p_granted': granted});

  @override
  Future<PrivacyStatus> recordNoticeView() =>
      _statusRpc('record_privacy_notice_view');

  @override
  Future<DeletionRequest> requestDeletion() async =>
      (await _deletionRpc('request_account_deletion'))!;

  @override
  Future<DeletionRequest> cancelDeletion() async =>
      (await _deletionRpc('cancel_account_deletion'))!;

  @override
  Future<DeletionRequest?> myDeletionRequest() =>
      _deletionRpc('my_deletion_request');

  @override
  Future<List<RetainedEntry>> retainedEntries() => _guard(() async {
    final r = await _client.rpc<List<dynamic>>('list_my_retained_entries');
    return [for (final e in r) RetainedEntry.fromJson(_map(e))];
  });

  @override
  Future<RetainedEntryDetail> requestRetainedEntry(
    String entryId, {
    required String reason,
  }) => _guard(() async {
    final r = await _client.rpc<Object?>(
      'request_retained_entry',
      params: {'p_entry_id': entryId, 'p_reason': reason.trim()},
    );
    return RetainedEntryDetail.fromJson(_map(r));
  });
}
