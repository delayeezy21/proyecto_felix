import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error legible de mascotas y direcciones.
class OwnerDataFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'OwnerDataFailure: $message';
}

abstract interface class PetRepository {
  /// Mascotas del dueño actual (activas primero), con especie y raza en la
  /// misma consulta.
  Future<List<Pet>> myPets();

  Future<void> create(PetDraft draft);

  Future<void> update(String id, PetDraft draft);

  /// No se borran: se desactivan (y se pueden reactivar).
  Future<void> setActive(String id, {required bool active});
}

abstract interface class AddressRepository {
  Future<List<Address>> myAddresses();

  /// Comunas compatibles con el punto (RPC `communes_at_point`), la más
  /// probable primero. Vacía si el punto no está en Chile.
  Future<List<CommuneMatch>> communesAt(GeoPoint point);

  Future<void> create(AddressDraft draft);

  Future<void> update(String id, AddressDraft draft);

  Future<void> setActive(String id, {required bool active});
}

String _uid(SupabaseClient client) {
  final uid = client.auth.currentUser?.id;
  if (uid == null) throw const OwnerDataFailure('Tu sesión expiró.');
  return uid;
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw OwnerDataFailure(switch (e.code) {
      // Los guardianes de la BD responden en español.
      '22023' => e.message,
      '23514' => 'Algún dato no es válido. Revisa el formulario.',
      '23503' => 'Algún dato del catálogo ya no existe.',
      '42501' => 'No tienes permiso para esta acción.',
      _ => 'No se pudo guardar. Inténtalo de nuevo.',
    });
  }
}

class SupabasePetRepository implements PetRepository {
  new(this._client);

  final SupabaseClient _client;

  static const _columns =
      'id, name, species_id, breed_id, sex, birth_date_approx, sterilized, '
      'microchip, active, species(name), breeds(name)';

  // Se filtra por el usuario actual aunque la RLS ya lo haga (CLAUDE.md).
  @override
  Future<List<Pet>> myPets() => _guard(() async {
    final rows = await _client
        .from('pets')
        .select(_columns)
        .eq('owner_id', _uid(_client))
        .order('active', ascending: false)
        .order('name');
    return [for (final r in rows) petFromRow(r)];
  });

  @override
  Future<void> create(PetDraft draft) => _guard(
    () => _client.from('pets').insert({
      'owner_id': _uid(_client),
      ...draft.toRow(),
    }),
  );

  @override
  Future<void> update(String id, PetDraft draft) => _guard(
    () => _client
        .from('pets')
        .update(draft.toRow())
        .eq('id', id)
        .eq('owner_id', _uid(_client)),
  );

  @override
  Future<void> setActive(String id, {required bool active}) => _guard(
    () => _client
        .from('pets')
        .update({'active': active})
        .eq('id', id)
        .eq('owner_id', _uid(_client)),
  );
}

Pet petFromRow(Map<String, dynamic> r) => Pet(
  id: r['id'] as String,
  name: r['name'] as String,
  speciesId: r['species_id'] as int,
  speciesName: (r['species'] as Map?)?['name'] as String?,
  breedId: r['breed_id'] as int?,
  breedName: (r['breeds'] as Map?)?['name'] as String?,
  sex: PetSex.parse(r['sex'] as String?),
  birthDateApprox: DateTime.tryParse(r['birth_date_approx'] as String? ?? ''),
  sterilized: r['sterilized'] as bool,
  microchip: r['microchip'] as String?,
  active: r['active'] as bool,
);

class SupabaseAddressRepository implements AddressRepository {
  new(this._client);

  final SupabaseClient _client;

  static const _columns =
      'id, label, street_text, details, commune_id, lat, lng, active, '
      'communes(name, region_id)';

  @override
  Future<List<Address>> myAddresses() => _guard(() async {
    final rows = await _client
        .from('addresses')
        .select(_columns)
        .eq('owner_id', _uid(_client))
        .order('active', ascending: false)
        .order('label');
    return [for (final r in rows) addressFromRow(r)];
  });

  @override
  Future<List<CommuneMatch>> communesAt(GeoPoint point) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'communes_at_point',
      params: {'p_lat': point.lat, 'p_lng': point.lng},
    );
    return [
      for (final r in rows.cast<Map<String, dynamic>>())
        CommuneMatch(
          communeId: r['commune_id'] as int,
          regionId: r['region_id'] as int,
          name: r['name'] as String,
          distanceMeters: (r['distance_m'] as num).toDouble(),
        ),
    ];
  });

  @override
  Future<void> create(AddressDraft draft) => _guard(
    () => _client.from('addresses').insert({
      'owner_id': _uid(_client),
      ...draft.toRow(),
    }),
  );

  @override
  Future<void> update(String id, AddressDraft draft) => _guard(
    () => _client
        .from('addresses')
        .update(draft.toRow())
        .eq('id', id)
        .eq('owner_id', _uid(_client)),
  );

  @override
  Future<void> setActive(String id, {required bool active}) => _guard(
    () => _client
        .from('addresses')
        .update({'active': active})
        .eq('id', id)
        .eq('owner_id', _uid(_client)),
  );
}

Address addressFromRow(Map<String, dynamic> r) {
  final commune = r['communes'] as Map?;
  return Address(
    id: r['id'] as String,
    label: r['label'] as String,
    streetText: r['street_text'] as String,
    details: r['details'] as String?,
    communeId: r['commune_id'] as int,
    communeName: commune?['name'] as String?,
    regionId: commune?['region_id'] as int?,
    point: GeoPoint((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble()),
    active: r['active'] as bool,
  );
}
