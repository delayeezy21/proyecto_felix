import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

class GeocodingFailure implements Exception {
  const new([
    this.message =
        'El buscador de direcciones no está disponible. '
        'Marca el punto en el mapa.',
  ]);

  final String message;

  @override
  String toString() => 'GeocodingFailure: $message';
}

/// Búsqueda de direcciones y geocodificación inversa, independiente del
/// proveedor. La dirección se geocodifica una sola vez, al guardarla
/// (docs/arquitectura.md §8): nunca en segundo plano ni para listar.
abstract interface class GeocodingAdapter {
  MapProvider get provider;

  /// Hasta 5 resultados en Chile. Una consulta de menos de 3 letras devuelve
  /// una lista vacía sin llamar al proveedor.
  Future<List<GeocodingResult>> search(String query);

  /// Dirección aproximada de un punto (o null si no hay).
  Future<GeocodingResult?> reverse(GeoPoint point);
}

/// Normaliza una consulta para la caché y para decidir si vale la pena buscar.
String normalizeQuery(String query) =>
    query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

const minQueryLength = 3;

/// Caché en memoria (LRU) y deduplicación de peticiones en curso.
///
/// Reduce el uso de Nominatim, cuya política prohíbe el uso intensivo, y el
/// costo de Google. Envuelve a cualquier [GeocodingAdapter].
class CachingGeocodingAdapter implements GeocodingAdapter {
  new(this._inner, {this.maxEntries = 100});

  final GeocodingAdapter _inner;
  final int maxEntries;
  // Los literales de Map son LinkedHashMap: conservan el orden de inserción.
  final _search = <String, List<GeocodingResult>>{};
  final _reverse = <String, GeocodingResult?>{};
  final _inFlight = <String, Future<Object?>>{};

  @override
  MapProvider get provider => _inner.provider;

  @override
  Future<List<GeocodingResult>> search(String query) async {
    final key = normalizeQuery(query);
    if (key.length < minQueryLength) return const [];
    final cached = _get(_search, key);
    if (cached != null) return cached;
    final result = await _dedupe('s:$key', () => _inner.search(query));
    final list = result! as List<GeocodingResult>;
    _put(_search, key, list);
    return list;
  }

  @override
  Future<GeocodingResult?> reverse(GeoPoint point) async {
    final key = point.cacheKey;
    if (_reverse.containsKey(key)) {
      return _get<GeocodingResult?>(_reverse, key);
    }
    final result = await _dedupe(
      'r:$key',
      () => _inner.reverse(point),
    ) as GeocodingResult?;
    _put(_reverse, key, result);
    return result;
  }

  Future<Object?> _dedupe(String key, Future<Object?> Function() run) {
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _runOnce(key, run);
    _inFlight[key] = future;
    return future;
  }

  Future<Object?> _runOnce(String key, Future<Object?> Function() run) async {
    try {
      return await run();
    } finally {
      // removeWhere (void): remove() devolvería el propio future.
      _inFlight.removeWhere((k, _) => k == key);
    }
  }

  V? _get<V>(Map<String, V> map, String key) {
    if (!map.containsKey(key)) return null;
    // Reinsertar = marcar como usado recientemente.
    final value = map.remove(key) as V;
    map[key] = value;
    return value;
  }

  void _put<V>(Map<String, V> map, String key, V value) {
    map[key] = value;
    while (map.length > maxEntries) {
      map.remove(map.keys.first);
    }
  }
}
