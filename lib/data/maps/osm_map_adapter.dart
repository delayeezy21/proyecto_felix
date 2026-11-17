import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

/// Mapa con tiles raster tipo OpenStreetMap (`flutter_map`).
///
/// La URL de tiles es configurable (`OSM_TILE_URL`): los tiles públicos de la
/// OSMF solo sirven para desarrollo; en producción, Stadia o MapTiler.
class OsmMapAdapter implements MapAdapter {
  const new({
    required this.tileUrl,
    required this.attribution,
    this.tileProvider,
  });

  final String tileUrl;

  @override
  final String attribution;

  /// Se sobrescribe en los tests para no pedir tiles a la red.
  final TileProvider? tileProvider;

  /// Identifica la app ante el servidor de tiles (sin datos personales).
  static const userAgentPackageName = 'cl.proyectofelix.proyecto_felix';

  @override
  MapProvider get provider => MapProvider.osm;

  @override
  Widget buildMap({
    required GeoPoint center,
    double zoom = 15,
    List<MapMarker> markers = const [],
    List<List<GeoPoint>> polylines = const [],
    ValueChanged<GeoPoint>? onTap,
    MapViewController? controller,
    Key? key,
  }) => _OsmMap(
    key: key,
    adapter: this,
    center: center,
    zoom: zoom,
    markers: markers,
    polylines: polylines,
    onTap: onTap,
    controller: controller,
  );
}

ll.LatLng _toLatLng(GeoPoint p) => ll.LatLng(p.lat, p.lng);

class _OsmMap extends StatefulWidget {
  const new({
    required this.adapter,
    required this.center,
    required this.zoom,
    required this.markers,
    required this.polylines,
    this.onTap,
    this.controller,
    super.key,
  });

  final OsmMapAdapter adapter;
  final GeoPoint center;
  final double zoom;
  final List<MapMarker> markers;
  final List<List<GeoPoint>> polylines;
  final ValueChanged<GeoPoint>? onTap;
  final MapViewController? controller;

  @override
  State<_OsmMap> createState() => _OsmMapState();
}

class _OsmMapState extends State<_OsmMap> {
  final _map = MapController();
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.attach(_animate);
  }

  @override
  void didUpdateWidget(covariant _OsmMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.attach(null);
      widget.controller?.attach(_animate);
    }
  }

  @override
  void dispose() {
    widget.controller?.attach(null);
    _map.dispose();
    super.dispose();
  }

  Future<void> _animate(GeoPoint point, double zoom) async {
    if (!_ready) return;
    _map.move(_toLatLng(point), zoom);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _toLatLng(widget.center),
        initialZoom: widget.zoom,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: () => _ready = true,
        onTap: widget.onTap == null
            ? null
            : (_, p) => widget.onTap!(GeoPoint(p.latitude, p.longitude)),
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: widget.adapter.tileUrl,
          userAgentPackageName: OsmMapAdapter.userAgentPackageName,
          tileProvider: widget.adapter.tileProvider,
        ),
        if (widget.polylines.isNotEmpty)
          PolylineLayer(
            polylines: [
              for (final line in widget.polylines)
                Polyline(
                  points: [for (final p in line) _toLatLng(p)],
                  strokeWidth: 4,
                  color: scheme.primary,
                ),
            ],
          ),
        MarkerLayer(
          markers: [
            for (final m in widget.markers)
              Marker(
                key: ValueKey('marker-${m.id}'),
                point: _toLatLng(m.point),
                width: 44,
                height: 44,
                alignment: Alignment.topCenter,
                child: Semantics(
                  label: m.label ?? 'Ubicación marcada',
                  child: Icon(Icons.location_on, size: 44, color: scheme.error),
                ),
              ),
          ],
        ),
        // Atribución obligatoria. Se ajusta en varias líneas en pantallas
        // angostas o con texto grande (SimpleAttributionWidget se desborda).
        Align(
          alignment: Alignment.bottomRight,
          child: Container(
            margin: const EdgeInsets.all(4),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: scheme.surface.withValues(alpha: 0.85),
            child: Text(
              widget.adapter.attribution,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
      ],
    );
  }
}
