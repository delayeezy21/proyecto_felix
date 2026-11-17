import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/maps/google_maps_loader_stub.dart'
    if (dart.library.js_interop) 'package:proyecto_felix/data/maps/google_maps_loader_web.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

/// Mapa de Google (`google_maps_flutter`). Solo Android y Web: Windows no está
/// soportado por el plugin y siempre usa [MapProvider.osm].
class GoogleMapAdapter implements MapAdapter {
  const new({required this.apiKey, this.loader = ensureGoogleMapsLoaded});

  final String apiKey;

  /// Carga del SDK (en Web inyecta el script; se reemplaza en los tests).
  final Future<void> Function(String apiKey) loader;

  @override
  MapProvider get provider => MapProvider.google;

  @override
  String get attribution => 'Google';

  @override
  Widget buildMap({
    required GeoPoint center,
    double zoom = 15,
    List<MapMarker> markers = const [],
    List<List<GeoPoint>> polylines = const [],
    ValueChanged<GeoPoint>? onTap,
    MapViewController? controller,
    Key? key,
  }) => _GoogleMap(
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

gm.LatLng _toLatLng(GeoPoint p) => gm.LatLng(p.lat, p.lng);

class _GoogleMap extends StatefulWidget {
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

  final GoogleMapAdapter adapter;
  final GeoPoint center;
  final double zoom;
  final List<MapMarker> markers;
  final List<List<GeoPoint>> polylines;
  final ValueChanged<GeoPoint>? onTap;
  final MapViewController? controller;

  @override
  State<_GoogleMap> createState() => _GoogleMapState();
}

class _GoogleMapState extends State<_GoogleMap> {
  late final Future<void> _loaded = widget.adapter.loader(
    widget.adapter.apiKey,
  );
  gm.GoogleMapController? _map;

  @override
  void initState() {
    super.initState();
    widget.controller?.attach(_animate);
  }

  @override
  void didUpdateWidget(covariant _GoogleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.attach(null);
      widget.controller?.attach(_animate);
    }
  }

  @override
  void dispose() {
    widget.controller?.attach(null);
    _map?.dispose();
    super.dispose();
  }

  Future<void> _animate(GeoPoint point, double zoom) async {
    await _map?.animateCamera(
      gm.CameraUpdate.newLatLngZoom(_toLatLng(point), zoom),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return FutureBuilder<void>(
      future: _loaded,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('No se pudo cargar el mapa.'));
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(semanticsLabel: 'Cargando mapa'),
          );
        }
        return gm.GoogleMap(
          initialCameraPosition: gm.CameraPosition(
            target: _toLatLng(widget.center),
            zoom: widget.zoom,
          ),
          onMapCreated: (c) => _map = c,
          onTap: widget.onTap == null
              ? null
              : (p) => widget.onTap!(GeoPoint(p.latitude, p.longitude)),
          markers: {
            for (final m in widget.markers)
              gm.Marker(
                markerId: gm.MarkerId(m.id),
                position: _toLatLng(m.point),
                infoWindow: m.label == null
                    ? gm.InfoWindow.noText
                    : gm.InfoWindow(title: m.label),
              ),
          },
          polylines: {
            for (final (i, line) in widget.polylines.indexed)
              gm.Polyline(
                polylineId: gm.PolylineId('line-$i'),
                points: [for (final p in line) _toLatLng(p)],
                color: color,
                width: 4,
              ),
          },
          rotateGesturesEnabled: false,
          tiltGesturesEnabled: false,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
        );
      },
    );
  }
}
