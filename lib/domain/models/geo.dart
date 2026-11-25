import 'package:flutter/foundation.dart' show immutable;

/// Punto geográfico (WGS84). Independiente del proveedor de mapas.
@immutable
class GeoPoint {
  const new(this.lat, this.lng);

  final double lat;
  final double lng;

  /// Santiago centro: punto inicial cuando aún no hay dirección.
  static const santiago = GeoPoint(-33.4489, -70.6693);

  /// Centro inicial de los mapas: `--dart-define=MAP_DEFAULT_CENTER=lat,lng`
  /// (la beta local usa San Miguel); si falta o es inválido, Santiago centro.
  static final GeoPoint initial =
      tryParse(const String.fromEnvironment('MAP_DEFAULT_CENTER')) ?? santiago;

  /// Lee "lat,lng"; devuelve null si no es un punto válido en Chile.
  static GeoPoint? tryParse(String text) {
    final parts = text.split(',');
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0].trim());
    final lng = double.tryParse(parts[1].trim());
    if (lat == null || lng == null) return null;
    final p = GeoPoint(lat, lng);
    return p.isInChile ? p : null;
  }

  /// Chile continental, insular y antártico (mismo rango que la BD).
  bool get isInChile => lat >= -90 && lat <= -17 && lng >= -110 && lng <= -66;

  /// Clave de caché redondeada (~11 m) para no repetir geocodificaciones.
  String get cacheKey => '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}

/// Resultado de una búsqueda o geocodificación inversa.
@immutable
class GeocodingResult {
  const new({required this.label, required this.point, this.communeName});

  /// Texto legible de la dirección (calle y número si existen).
  final String label;
  final GeoPoint point;

  /// Comuna informada por el proveedor, si la trae (solo como sugerencia).
  final String? communeName;
}
