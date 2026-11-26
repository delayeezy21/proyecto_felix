import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/domain/models/subscription.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error legible de suscripciones.
class SubscriptionFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'SubscriptionFailure: $message';
}

/// Suscripciones simuladas (fase 10). El servidor valida el plan, las
/// mascotas, el cupo y cobra el primer mes; aquí solo se llaman las RPC.
abstract interface class SubscriptionRepository {
  /// Planes activos, en el orden del catálogo.
  Future<List<SubscriptionPlan>> plans();

  /// Mi suscripción abierta o vigente (null si no tengo).
  Future<Subscription?> mine();

  Future<Subscription> subscribe(int planId, List<String> petIds);

  Future<Subscription> setPets(List<String> petIds);

  /// Cancela: no se renueva y los beneficios siguen hasta fin del período.
  Future<Subscription> cancel();
}

Exception mapSubscriptionError(PostgrestException e) {
  if (isAccountBlocked(e)) return const AccountBlockedException();
  return switch (e.code) {
    // Validaciones del servidor (plan inactivo, mascotas, ya suscrito):
    // responden en español.
    '22023' => SubscriptionFailure(e.message),
    '42501' => const SubscriptionFailure(
      'Solo los dueños pueden contratar un plan.',
    ),
    '28000' => const SubscriptionFailure('Tu sesión expiró.'),
    _ => const SubscriptionFailure(
      'No se pudo completar la acción. Inténtalo de nuevo.',
    ),
  };
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw mapSubscriptionError(e);
  }
}

Map<String, dynamic> _map(Object? v) => (v! as Map).cast<String, dynamic>();

class SupabaseSubscriptionRepository implements SubscriptionRepository {
  new(this._client);

  final SupabaseClient _client;

  Future<Subscription> _call(String fn, [Map<String, dynamic>? params]) =>
      _guard(() async {
        final r = await _client.rpc<Object?>(fn, params: params);
        return Subscription.fromJson(_map(r));
      });

  @override
  Future<List<SubscriptionPlan>> plans() => _guard(() async {
    final rows = await _client
        .from('subscription_plans')
        .select(
          'id, slug, name, discount_pct, preventive_per_year, waive_urgent, '
          'max_pets, price_monthly',
        )
        .eq('active', true)
        .order('sort')
        .order('id');
    return [for (final r in rows) SubscriptionPlan.fromJson(r)];
  });

  @override
  Future<Subscription?> mine() => _guard(() async {
    final r = await _client.rpc<Object?>('my_subscription');
    return r == null ? null : Subscription.fromJson(_map(r));
  });

  @override
  Future<Subscription> subscribe(int planId, List<String> petIds) =>
      _call('subscribe', {'p_plan_id': planId, 'p_pet_ids': petIds});

  @override
  Future<Subscription> setPets(List<String> petIds) =>
      _call('set_subscription_pets', {'p_pet_ids': petIds});

  @override
  Future<Subscription> cancel() => _call('cancel_subscription');
}
