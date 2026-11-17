import 'package:flutter/material.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/repositories/owner_repositories.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';

/// Mascotas en memoria (las de un solo dueño).
class FakePetRepository implements PetRepository {
  new({List<Pet>? pets}) : pets = pets ?? [];

  final List<Pet> pets;
  final created = <PetDraft>[];
  final updated = <(String, PetDraft)>[];
  OwnerDataFailure? nextFailure;
  int listCalls = 0;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  Pet _fromDraft(String id, PetDraft d, {bool active = true}) => Pet(
    id: id,
    name: d.name.trim(),
    speciesId: d.speciesId,
    speciesName: d.speciesId == 1 ? 'Perro' : 'Gato',
    breedId: d.breedId,
    sex: d.sex,
    birthDateApprox: d.birthDateApprox,
    sterilized: d.sterilized,
    microchip: d.microchip,
    active: active,
  );

  @override
  Future<List<Pet>> myPets() async {
    listCalls++;
    return List.of(pets);
  }

  @override
  Future<void> create(PetDraft draft) async {
    _maybeFail();
    created.add(draft);
    pets.add(_fromDraft('p${pets.length + 1}', draft));
  }

  @override
  Future<void> update(String id, PetDraft draft) async {
    _maybeFail();
    updated.add((id, draft));
    final i = pets.indexWhere((p) => p.id == id);
    pets[i] = _fromDraft(id, draft, active: pets[i].active);
  }

  @override
  Future<void> setActive(String id, {required bool active}) async {
    _maybeFail();
    final i = pets.indexWhere((p) => p.id == id);
    pets[i] = _fromDraft(id, pets[i].toDraft(), active: active);
  }
}

class FakeAddressRepository implements AddressRepository {
  new({List<Address>? addresses}) : addresses = addresses ?? [];

  final List<Address> addresses;
  final created = <AddressDraft>[];
  final updated = <(String, AddressDraft)>[];
  OwnerDataFailure? nextFailure;

  Address _fromDraft(String id, AddressDraft d, {bool active = true}) =>
      Address(
        id: id,
        label: d.label.trim(),
        streetText: d.streetText.trim(),
        details: d.details,
        communeId: d.communeId,
        communeName: 'Ñuñoa',
        regionId: 13,
        point: d.point,
        active: active,
      );

  @override
  Future<List<Address>> myAddresses() async => List.of(addresses);

  @override
  Future<void> create(AddressDraft draft) async {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
    created.add(draft);
    addresses.add(_fromDraft('a${addresses.length + 1}', draft));
  }

  @override
  Future<void> update(String id, AddressDraft draft) async {
    updated.add((id, draft));
    final i = addresses.indexWhere((a) => a.id == id);
    addresses[i] = _fromDraft(id, draft, active: addresses[i].active);
  }

  @override
  Future<void> setActive(String id, {required bool active}) async {
    final i = addresses.indexWhere((a) => a.id == id);
    addresses[i] = _fromDraft(id, addresses[i].toDraft(), active: active);
  }
}

/// Geocoding sin red: responde lo que el test configure y registra llamadas.
class FakeGeocodingAdapter implements GeocodingAdapter {
  final searches = <String>[];
  final reverses = <GeoPoint>[];
  List<GeocodingResult> results = const [
    GeocodingResult(
      label: 'Av. Ficticia 123',
      point: GeoPoint(-33.4569, -70.5974),
      communeName: 'Ñuñoa',
    ),
    GeocodingResult(
      label: 'Av. Ficticia 456',
      point: GeoPoint(-33.4570, -70.5980),
      communeName: 'Ñuñoa',
    ),
  ];
  GeocodingResult? reverseResult = const GeocodingResult(
    label: 'Pasaje Inventado 77',
    point: GeoPoint(-33.45, -70.60),
  );
  bool fail = false;

  @override
  MapProvider get provider => MapProvider.osm;

  @override
  Future<List<GeocodingResult>> search(String query) async {
    searches.add(query);
    if (fail) throw const GeocodingFailure();
    return results;
  }

  @override
  Future<GeocodingResult?> reverse(GeoPoint point) async {
    reverses.add(point);
    if (fail) throw const GeocodingFailure();
    return reverseResult;
  }
}

/// Mapa falso: un área que, al tocarla, entrega [tapPoint].
class FakeMapAdapter implements MapAdapter {
  GeoPoint tapPoint = const GeoPoint(-33.4500, -70.6000);
  final animations = <GeoPoint>[];
  List<MapMarker> lastMarkers = const [];

  @override
  MapProvider get provider => MapProvider.osm;

  @override
  String get attribution => 'Mapa de prueba';

  @override
  Widget buildMap({
    required GeoPoint center,
    double zoom = 15,
    List<MapMarker> markers = const [],
    List<List<GeoPoint>> polylines = const [],
    ValueChanged<GeoPoint>? onTap,
    MapViewController? controller,
    Key? key,
  }) {
    lastMarkers = markers;
    controller?.attach((p, z) async => animations.add(p));
    return GestureDetector(
      key: const Key('fake-map'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap == null ? null : () => onTap(tapPoint),
      child: ColoredBox(
        color: const Color(0xFFE0E0E0),
        child: Center(child: Text('marcadores: ${markers.length}')),
      ),
    );
  }
}
