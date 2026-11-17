import 'package:flutter/widgets.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

/// Marcador en el mapa.
@immutable
class MapMarker {
  const new({required this.id, required this.point, this.label});

  final String id;
  final GeoPoint point;

  /// Texto accesible del marcador.
  final String? label;
}

/// Controla la cámara de un mapa construido por un [MapAdapter].
///
/// La implementación concreta la conecta el adaptador al construir el mapa;
/// antes de eso, [animateTo] no hace nada.
class MapViewController {
  Future<void> Function(GeoPoint point, double zoom)? _animate;

  /// Lo llama el adaptador al montar el mapa (y con null al desmontarlo).
  // ignore: use_setters_to_change_properties
  void attach(Future<void> Function(GeoPoint point, double zoom)? animate) =>
      _animate = animate;

  bool get isAttached => _animate != null;

  Future<void> animateTo(GeoPoint point, {double zoom = 16}) async {
    await _animate?.call(point, zoom);
  }
}

/// Mapa interactivo independiente del proveedor (docs/arquitectura.md §3).
///
/// Implementaciones: `GoogleMapAdapter` (Android y Web con API key) y
/// `OsmMapAdapter` (Windows, iOS por ahora, o sin API key). La UI nunca usa
/// `google_maps_flutter` ni `flutter_map` directamente.
abstract interface class MapAdapter {
  MapProvider get provider;

  /// Atribución obligatoria del proveedor (se muestra sobre el mapa).
  String get attribution;

  Widget buildMap({
    required GeoPoint center,
    double zoom = 15,
    List<MapMarker> markers = const [],
    List<List<GeoPoint>> polylines = const [],
    ValueChanged<GeoPoint>? onTap,
    MapViewController? controller,
    Key? key,
  });
}
