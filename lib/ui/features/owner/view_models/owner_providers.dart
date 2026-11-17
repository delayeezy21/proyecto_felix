import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/maps_providers.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';

// autoDispose: al cerrar sesión o cambiar de cuenta no queda la lista anterior
// en memoria (QA-15).
final FutureProvider<List<Pet>> myPetsProvider =
    FutureProvider.autoDispose<List<Pet>>(
      (ref) => ref.watch(petRepositoryProvider).myPets(),
    );

final FutureProvider<List<Address>> myAddressesProvider =
    FutureProvider.autoDispose<List<Address>>(
      (ref) => ref.watch(addressRepositoryProvider).myAddresses(),
    );

/// Razas activas de una especie (la lista se filtra al elegir la especie).
final FutureProviderFamily<List<Breed>, int> breedsProvider =
    FutureProvider.family<List<Breed>, int>(
      (ref, speciesId) =>
          ref.watch(catalogRepositoryProvider).breeds(speciesId),
    );

/// Comunas compatibles con un punto marcado (QA-F4-02), según los límites
/// comunales del servidor. La primera es la más probable; vacía = fuera de
/// Chile.
final FutureProviderFamily<List<CommuneMatch>, GeoPoint>
communesAtPointProvider = FutureProvider.autoDispose
    .family<List<CommuneMatch>, GeoPoint>(
      (ref, point) => ref.watch(addressRepositoryProvider).communesAt(point),
    );

/// Búsqueda de direcciones con debounce: solo consulta al proveedor cuando el
/// usuario deja de escribir [debounce] (Nominatim prohíbe el uso intensivo).
class AddressSearchController
    extends Notifier<AsyncValue<List<GeocodingResult>>> {
  static const debounce = Duration(milliseconds: 700);

  Timer? _timer;
  int _seq = 0;

  @override
  AsyncValue<List<GeocodingResult>> build() {
    ref.onDispose(() => _timer?.cancel());
    return const AsyncData([]);
  }

  /// [communeName] acota la búsqueda a la comuna elegida en el formulario.
  void queryChanged(String query, {String? communeName}) {
    _timer?.cancel();
    _seq++;
    if (normalizeQuery(query).length < minQueryLength) {
      state = const AsyncData([]);
      return;
    }
    final full = communeName == null ? query : '$query, $communeName';
    _timer = Timer(debounce, () => unawaited(_run(full)));
  }

  Future<void> _run(String query) async {
    final seq = ++_seq;
    state = const AsyncLoading();
    try {
      final results = await ref.read(geocodingAdapterProvider).search(query);
      if (!ref.mounted || seq != _seq) return;
      state = AsyncData(results);
    } on Object catch (e, st) {
      if (!ref.mounted || seq != _seq) return;
      state = AsyncError(e, st);
    }
  }

  void clear() {
    _timer?.cancel();
    _seq++;
    state = const AsyncData([]);
  }
}

final NotifierProvider<
  AddressSearchController,
  AsyncValue<List<GeocodingResult>>
>
addressSearchProvider = NotifierProvider.autoDispose(
  AddressSearchController.new,
);

/// Geocodificación inversa del punto marcado, con debounce (el usuario puede
/// tocar el mapa varias veces seguidas).
class ReverseGeocodeController extends Notifier<GeocodingResult?> {
  static const debounce = Duration(milliseconds: 900);

  Timer? _timer;
  int _seq = 0;

  @override
  GeocodingResult? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void pointChanged(GeoPoint point) {
    _timer?.cancel();
    final seq = ++_seq;
    state = null;
    _timer = Timer(debounce, () async {
      try {
        final r = await ref.read(geocodingAdapterProvider).reverse(point);
        if (ref.mounted && seq == _seq) state = r;
      } on Object {
        // Sin sugerencia: el punto marcado sigue siendo válido.
      }
    });
  }
}

final NotifierProvider<ReverseGeocodeController, GeocodingResult?>
reverseGeocodeProvider = NotifierProvider.autoDispose(
  ReverseGeocodeController.new,
);
