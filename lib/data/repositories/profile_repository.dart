import 'package:proyecto_felix/domain/models/account.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'ProfileFailure: $message';
}

abstract interface class ProfileRepository {
  /// Cuenta del usuario actual, o null si no ha completado el registro.
  Future<Account?> fetchAccount();

  Future<LegalVersions> fetchLegalVersions();

  /// Crea rol, perfil, aceptación de términos y aviso de privacidad en una sola
  /// transacción (RPC `complete_registration`).
  Future<void> completeRegistration({
    required AppRole role,
    required String displayName,
    required String? phone,
    required LegalVersions legal,
    required bool marketingConsent,
    int? communeId,
  });
}

class SupabaseProfileRepository implements ProfileRepository {
  new(this._client);

  final SupabaseClient _client;

  @override
  Future<Account?> fetchAccount() async {
    final roleRow = await _client
        .from('user_roles')
        .select('role')
        .maybeSingle();
    final role = AppRole.tryParse(roleRow?['role'] as String?);
    if (role == null) return null;

    switch (role) {
      case AppRole.owner:
        final p = await _client
            .from('owner_profiles')
            .select('display_name')
            .single();
        return Account(role: role, displayName: p['display_name'] as String);
      case AppRole.vet:
        final p = await _client
            .from('vet_profiles')
            .select('display_name, status')
            .single();
        return Account(
          role: role,
          displayName: p['display_name'] as String,
          vetStatus: VetStatus.parse(p['status'] as String?),
        );
      case AppRole.admin:
      case AppRole.foundation:
        return Account(
          role: role,
          displayName: _client.auth.currentUser?.email ?? '',
        );
    }
  }

  @override
  Future<LegalVersions> fetchLegalVersions() async {
    final terms = await _client.rpc<String?>(
      'current_legal_version',
      params: {'p_kind': 'terms'},
    );
    final privacy = await _client.rpc<String?>(
      'current_legal_version',
      params: {'p_kind': 'privacy'},
    );
    if (terms == null || privacy == null) {
      throw const ProfileFailure('No hay documentos legales vigentes.');
    }
    return LegalVersions(terms: terms, privacy: privacy);
  }

  @override
  Future<void> completeRegistration({
    required AppRole role,
    required String displayName,
    required String? phone,
    required LegalVersions legal,
    required bool marketingConsent,
    int? communeId,
  }) async {
    try {
      await _client.rpc<String>(
        'complete_registration',
        params: {
          'p_role': role.name,
          'p_display_name': displayName.trim(),
          'p_phone': phone?.trim(),
          'p_terms_version': legal.terms,
          'p_privacy_version': legal.privacy,
          'p_commune_id': communeId,
        },
      );
      if (marketingConsent) {
        await _client.from('consents').insert({
          'user_id': _client.auth.currentUser!.id,
          'purpose': 'marketing',
          'version': legal.privacy,
        });
      }
    } on PostgrestException catch (e) {
      throw ProfileFailure(switch (e.code) {
        '23505' => 'Tu cuenta ya completó el registro.',
        '22023' =>
          'Los términos o la política cambiaron. Vuelve a abrir el registro.',
        _ => 'No se pudo completar el registro. Inténtalo de nuevo.',
      });
    }
  }
}
