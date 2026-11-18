import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error legible de cotizaciones y fundaciones.
class PricingFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'PricingFailure: $message';
}

abstract interface class QuoteRepository {
  /// Pide la cotización al servidor (`quote_visit`). El cliente nunca envía
  /// montos.
  Future<Quote> quote(QuoteRequest request);
}

abstract interface class FoundationRepository {
  /// Fundaciones activas (para que el dueño elija). Para el admin incluye las
  /// inactivas (la RLS decide).
  Future<List<Foundation>> foundations();

  /// Fundación elegida en el perfil del dueño actual (null = la por defecto).
  Future<String?> myFoundationId();

  Future<void> setMyFoundation(String? foundationId);

  /// Fundación del miembro actual (rol `foundation`).
  Future<Foundation?> memberFoundation();

  /// Totales agregados por mes de la fundación del miembro actual.
  Future<List<FoundationMonth>> summary({int months = 12});

  Future<void> create(FoundationDraft draft);

  Future<void> update(String id, FoundationDraft draft);

  Future<void> setActive(String id, {required bool active});

  Future<void> setDefault(String id);
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw PricingFailure(switch (e.code) {
      // Las validaciones del servidor responden en español.
      '22023' => e.message,
      '23505' => 'Ya existe una fundación con ese nombre.',
      '23514' when e.message.contains('foundations_default_active') =>
        'La fundación por defecto no se puede desactivar.',
      '23514' => 'Algún dato no es válido. Revisa el formulario.',
      '42501' => 'No tienes permiso para esta acción.',
      _ => 'No se pudo completar la acción. Inténtalo de nuevo.',
    });
  }
}

String _uid(SupabaseClient client) {
  final uid = client.auth.currentUser?.id;
  if (uid == null) throw const PricingFailure('Tu sesión expiró.');
  return uid;
}

class SupabaseQuoteRepository implements QuoteRepository {
  new(this._client);

  final SupabaseClient _client;

  @override
  Future<Quote> quote(QuoteRequest request) => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'quote_visit',
      params: request.toParams(),
    );
    return Quote.fromJson(json);
  });
}

class SupabaseFoundationRepository implements FoundationRepository {
  new(this._client);

  final SupabaseClient _client;

  static const _columns = 'id, name, description, website, active, is_default';

  static Foundation _fromRow(Map<String, dynamic> r) => Foundation(
    id: r['id'] as String,
    name: r['name'] as String,
    description: r['description'] as String?,
    website: r['website'] as String?,
    active: r['active'] as bool,
    isDefault: r['is_default'] as bool,
  );

  @override
  Future<List<Foundation>> foundations() => _guard(() async {
    final rows = await _client
        .from('foundations')
        .select(_columns)
        .order('is_default', ascending: false)
        .order('name');
    return [for (final r in rows) _fromRow(r)];
  });

  // Filtra por el usuario actual: la RLS deja al admin ver todos los perfiles.
  @override
  Future<String?> myFoundationId() => _guard(() async {
    final row = await _client
        .from('owner_profiles')
        .select('foundation_id')
        .eq('user_id', _uid(_client))
        .maybeSingle();
    return row?['foundation_id'] as String?;
  });

  @override
  Future<void> setMyFoundation(String? foundationId) => _guard(
    () => _client
        .from('owner_profiles')
        .update({'foundation_id': foundationId})
        .eq('user_id', _uid(_client)),
  );

  @override
  Future<Foundation?> memberFoundation() => _guard(() async {
    final m = await _client
        .from('foundation_members')
        .select('foundations($_columns)')
        .eq('user_id', _uid(_client))
        .eq('active', true)
        .maybeSingle();
    final f = m?['foundations'] as Map<String, dynamic>?;
    return f == null ? null : _fromRow(f);
  });

  @override
  Future<List<FoundationMonth>> summary({int months = 12}) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'foundation_summary',
      params: {'p_months': months},
    );
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        FoundationMonth(
          month: DateTime.parse(r['month'] as String),
          commissionTotal: (r['commission_total'] as num).toInt(),
          donationTotal: (r['donation_total'] as num).toInt(),
          total: (r['total'] as num).toInt(),
        ),
    ];
  });

  @override
  Future<void> create(FoundationDraft draft) =>
      _guard(() => _client.from('foundations').insert(draft.toRow()));

  @override
  Future<void> update(String id, FoundationDraft draft) => _guard(
    () => _client.from('foundations').update(draft.toRow()).eq('id', id),
  );

  @override
  Future<void> setActive(String id, {required bool active}) => _guard(
    () => _client.from('foundations').update({'active': active}).eq('id', id),
  );

  @override
  Future<void> setDefault(String id) => _guard(
    () => _client.rpc<void>(
      'set_default_foundation',
      params: {'p_foundation_id': id},
    ),
  );
}
