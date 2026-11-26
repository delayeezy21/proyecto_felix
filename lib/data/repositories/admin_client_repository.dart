import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/domain/models/admin_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error legible de la consulta de clientes.
class AdminClientFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'AdminClientFailure: $message';
}

/// Clientes (dueños) para el soporte del admin. El servidor decide qué datos
/// se entregan (minimización y cuentas en borrado).
abstract interface class AdminClientRepository {
  Future<List<AdminClient>> list({String? search, int limit = 200});

  Future<AdminClientDetail> detail(String userId);
}

Exception mapAdminClientError(PostgrestException e) {
  // El cliente bloqueado es otra cuenta: no es la sesión del admin.
  if (e.hint == 'counterpart_blocked') {
    return const AdminClientFailure(
      'Esta cuenta está en proceso de borrado: sus datos ya no se pueden '
      'consultar.',
    );
  }
  if (isAccountBlocked(e)) return const AccountBlockedException();
  return switch (e.code) {
    '22023' => AdminClientFailure(e.message),
    '42501' => const AdminClientFailure('Solo el administrador ve clientes.'),
    '28000' => const AdminClientFailure('Tu sesión expiró.'),
    _ => const AdminClientFailure(
      'No se pudo cargar la información. Inténtalo de nuevo.',
    ),
  };
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw mapAdminClientError(e);
  }
}

class SupabaseAdminClientRepository implements AdminClientRepository {
  new(this._client);

  final SupabaseClient _client;

  @override
  Future<List<AdminClient>> list({String? search, int limit = 200}) =>
      _guard(() async {
        final q = search?.trim();
        final rows = await _client.rpc<List<dynamic>>(
          'admin_list_owners',
          params: {
            'p_search': (q == null || q.isEmpty) ? null : q,
            'p_limit': limit,
          },
        );
        return [
          for (final r in rows)
            AdminClient.fromJson((r as Map).cast<String, dynamic>()),
        ];
      });

  @override
  Future<AdminClientDetail> detail(String userId) => _guard(() async {
    final r = await _client.rpc<Object?>(
      'admin_owner_detail',
      params: {'p_owner_id': userId},
    );
    return AdminClientDetail.fromJson((r! as Map).cast<String, dynamic>());
  });
}
