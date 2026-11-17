import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/pet.dart' show Breed;
import 'package:supabase_flutter/supabase_flutter.dart';

class CatalogFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'CatalogFailure: $message';
}

abstract interface class CatalogRepository {
  Future<List<Region>> regions();

  Future<List<Commune>> communes(int regionId);

  /// Razas activas de una especie (puede no tener ninguna).
  Future<List<Breed>> breeds(int speciesId);

  /// Para el admin incluye los inactivos (la RLS decide qué se ve).
  Future<List<CatalogItem>> items(CatalogKind kind);

  Future<void> createItem(CatalogKind kind, String name);

  Future<void> renameItem(CatalogKind kind, int id, String name);

  Future<void> setItemActive(CatalogKind kind, int id, {required bool active});

  Future<List<Tariff>> tariffs();

  Future<void> updateTariffPrice(int id, int basePrice);

  Future<PricingConfig> currentPricing();

  /// Crea una nueva versión vigente (la anterior se conserva).
  Future<void> createPricingVersion(PricingConfig config);

  Future<List<EmergencyClinic>> clinics();

  Future<void> createClinic({
    required String name,
    required int communeId,
    required String address,
    required String phone,
  });

  Future<void> setClinicActive(String id, {required bool active});
}

class SupabaseCatalogRepository implements CatalogRepository {
  new(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Region>> regions() => _guard(() async {
    final rows = await _client.from('regions').select('id, name').order('sort');
    return [
      for (final r in rows)
        Region(id: r['id'] as int, name: r['name'] as String),
    ];
  });

  @override
  Future<List<Commune>> communes(int regionId) => _guard(() async {
    final rows = await _client
        .from('communes')
        .select('id, region_id, name')
        .eq('region_id', regionId)
        .order('name');
    return [
      for (final r in rows)
        Commune(
          id: r['id'] as int,
          regionId: r['region_id'] as int,
          name: r['name'] as String,
        ),
    ];
  });

  @override
  Future<List<Breed>> breeds(int speciesId) => _guard(() async {
    final rows = await _client
        .from('breeds')
        .select('id, species_id, name')
        .eq('species_id', speciesId)
        .eq('active', true)
        .order('name');
    return [
      for (final r in rows)
        Breed(
          id: r['id'] as int,
          speciesId: r['species_id'] as int,
          name: r['name'] as String,
        ),
    ];
  });

  @override
  Future<List<CatalogItem>> items(CatalogKind kind) => _guard(() async {
    final rows = await _client
        .from(kind.table)
        .select('id, slug, name, active')
        .order('sort')
        .order('name');
    return [
      for (final r in rows)
        CatalogItem(
          id: r['id'] as int,
          slug: r['slug'] as String,
          name: r['name'] as String,
          active: r['active'] as bool,
        ),
    ];
  });

  @override
  Future<void> createItem(CatalogKind kind, String name) => _guard(
    () => _client.from(kind.table).insert({
      'slug': slugify(name),
      'name': name.trim(),
    }),
  );

  @override
  Future<void> renameItem(CatalogKind kind, int id, String name) => _guard(
    () => _client.from(kind.table).update({'name': name.trim()}).eq('id', id),
  );

  @override
  Future<void> setItemActive(
    CatalogKind kind,
    int id, {
    required bool active,
  }) => _guard(
    () => _client.from(kind.table).update({'active': active}).eq('id', id),
  );

  @override
  Future<List<Tariff>> tariffs() => _guard(() async {
    final rows = await _client
        .from('tariffs')
        .select('id, base_price, active, specialties(name), species(name)')
        .order('specialty_id');
    return [
      for (final r in rows)
        Tariff(
          id: r['id'] as int,
          specialtyName: (r['specialties'] as Map)['name'] as String,
          speciesName: (r['species'] as Map?)?['name'] as String?,
          basePrice: r['base_price'] as int,
          active: r['active'] as bool,
        ),
    ];
  });

  @override
  Future<void> updateTariffPrice(int id, int basePrice) => _guard(
    () =>
        _client.from('tariffs').update({'base_price': basePrice}).eq('id', id),
  );

  @override
  Future<PricingConfig> currentPricing() => _guard(() async {
    final r = await _client.rpc<List<dynamic>>('current_pricing_config');
    final row = r.first as Map<String, dynamic>;
    return PricingConfig(
      commissionPct: (row['commission_pct'] as num).toDouble(),
      foundationPct: (row['foundation_pct'] as num).toDouble(),
      urgentPct: (row['urgent_pct'] as num).toDouble(),
      perKm: row['per_km'] as int,
      freeKm: row['free_km'] as int,
      cancelFee: row['cancel_fee'] as int,
      effectiveFrom: DateTime.tryParse(row['effective_from'] as String? ?? ''),
    );
  });

  @override
  Future<void> createPricingVersion(PricingConfig c) => _guard(
    () => _client.from('pricing_config').insert({
      'commission_pct': c.commissionPct,
      'foundation_pct': c.foundationPct,
      'urgent_pct': c.urgentPct,
      'per_km': c.perKm,
      'free_km': c.freeKm,
      'cancel_fee': c.cancelFee,
      'created_by': _client.auth.currentUser?.id,
    }),
  );

  @override
  Future<List<EmergencyClinic>> clinics() => _guard(() async {
    final rows = await _client
        .from('emergency_clinics')
        .select('id, name, commune_id, address, phone, active, communes(name)')
        .order('name');
    return [
      for (final r in rows)
        EmergencyClinic(
          id: r['id'] as String,
          name: r['name'] as String,
          communeId: r['commune_id'] as int,
          communeName: (r['communes'] as Map)['name'] as String,
          address: r['address'] as String,
          phone: r['phone'] as String,
          active: r['active'] as bool,
        ),
    ];
  });

  @override
  Future<void> createClinic({
    required String name,
    required int communeId,
    required String address,
    required String phone,
  }) => _guard(
    () => _client.from('emergency_clinics').insert({
      'name': name.trim(),
      'commune_id': communeId,
      'address': address.trim(),
      'phone': phone.trim(),
    }),
  );

  @override
  Future<void> setClinicActive(String id, {required bool active}) => _guard(
    () => _client
        .from('emergency_clinics')
        .update({'active': active})
        .eq('id', id),
  );

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PostgrestException catch (e) {
      throw CatalogFailure(switch (e.code) {
        '23505' => 'Ya existe un registro con ese nombre.',
        '23514' => 'Algún valor está fuera de rango.',
        '42501' => 'No tienes permiso para esta acción.',
        _ => 'No se pudo guardar. Inténtalo de nuevo.',
      });
    }
  }
}
