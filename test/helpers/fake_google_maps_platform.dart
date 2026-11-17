import 'dart:async';

import 'package:flutter/services.dart' show PlatformViewCreatedCallback;
import 'package:flutter/widgets.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

/// Plataforma de Google Maps falsa: no crea vistas nativas ni llama a Google.
/// Registra lo que el plugin le envía y permite simular toques.
class FakeGoogleMapsPlatform extends GoogleMapsFlutterPlatform {
  final _events = StreamController<MapEvent<Object?>>.broadcast();
  final cameraUpdates = <CameraUpdate>[];
  Set<Marker> markers = {};
  Set<Polyline> polylines = {};
  CameraPosition? initialCamera;
  int? lastMapId;

  /// Simula que el usuario toca el mapa en [position].
  void tap(LatLng position) => _events.add(MapTapEvent(lastMapId!, position));

  Stream<T> _on<T extends MapEvent<Object?>>(int mapId) =>
      _events.stream.where((e) => e is T && e.mapId == mapId).cast<T>();

  @override
  Widget buildViewWithConfiguration(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required MapWidgetConfiguration widgetConfiguration,
    MapConfiguration mapConfiguration = const MapConfiguration(),
    MapObjects mapObjects = const MapObjects(),
  }) {
    lastMapId = creationId;
    initialCamera = widgetConfiguration.initialCameraPosition;
    markers = mapObjects.markers;
    polylines = mapObjects.polylines;
    scheduleMicrotask(() => onPlatformViewCreated(creationId));
    return const SizedBox.expand(key: Key('fake-google-map'));
  }

  @override
  Future<void> init(int mapId) async {}

  @override
  Future<void> updateMapConfiguration(
    MapConfiguration configuration, {
    required int mapId,
  }) async {}

  @override
  Future<void> updateMarkers(
    MarkerUpdates markerUpdates, {
    required int mapId,
  }) async {
    markers = {
      ...markers.where(
        (m) => !markerUpdates.markerIdsToRemove.contains(m.markerId),
      ),
      ...markerUpdates.markersToAdd,
    };
  }

  @override
  Future<void> updatePolylines(
    PolylineUpdates polylineUpdates, {
    required int mapId,
  }) async {}

  @override
  Future<void> updatePolygons(
    PolygonUpdates polygonUpdates, {
    required int mapId,
  }) async {}

  @override
  Future<void> updateCircles(
    CircleUpdates circleUpdates, {
    required int mapId,
  }) async {}

  @override
  Future<void> updateHeatmaps(
    HeatmapUpdates heatmapUpdates, {
    required int mapId,
  }) async {}

  @override
  Future<void> updateTileOverlays({
    required Set<TileOverlay> newTileOverlays,
    required int mapId,
  }) async {}

  @override
  Future<void> updateClusterManagers(
    ClusterManagerUpdates clusterManagerUpdates, {
    required int mapId,
  }) async {}

  @override
  Future<void> updateGroundOverlays(
    GroundOverlayUpdates groundOverlayUpdates, {
    required int mapId,
  }) async {}

  @override
  Future<void> animateCamera(
    CameraUpdate cameraUpdate, {
    required int mapId,
  }) async => cameraUpdates.add(cameraUpdate);

  @override
  Future<void> animateCameraWithConfiguration(
    CameraUpdate cameraUpdate,
    CameraUpdateAnimationConfiguration configuration, {
    required int mapId,
  }) async => cameraUpdates.add(cameraUpdate);

  @override
  Future<void> moveCamera(
    CameraUpdate cameraUpdate, {
    required int mapId,
  }) async => cameraUpdates.add(cameraUpdate);

  @override
  Stream<CameraMoveStartedEvent> onCameraMoveStarted({required int mapId}) =>
      _on(mapId);

  @override
  Stream<CameraMoveEvent> onCameraMove({required int mapId}) => _on(mapId);

  @override
  Stream<CameraIdleEvent> onCameraIdle({required int mapId}) => _on(mapId);

  @override
  Stream<MarkerTapEvent> onMarkerTap({required int mapId}) => _on(mapId);

  @override
  Stream<InfoWindowTapEvent> onInfoWindowTap({required int mapId}) =>
      _on(mapId);

  @override
  Stream<MarkerDragStartEvent> onMarkerDragStart({required int mapId}) =>
      _on(mapId);

  @override
  Stream<MarkerDragEvent> onMarkerDrag({required int mapId}) => _on(mapId);

  @override
  Stream<MarkerDragEndEvent> onMarkerDragEnd({required int mapId}) =>
      _on(mapId);

  @override
  Stream<PolylineTapEvent> onPolylineTap({required int mapId}) => _on(mapId);

  @override
  Stream<PolygonTapEvent> onPolygonTap({required int mapId}) => _on(mapId);

  @override
  Stream<CircleTapEvent> onCircleTap({required int mapId}) => _on(mapId);

  @override
  Stream<PointOfInterestTapEvent> onPointOfInterestTap({required int mapId}) =>
      _on(mapId);

  @override
  Stream<MapTapEvent> onTap({required int mapId}) => _on(mapId);

  @override
  Stream<MapLongPressEvent> onLongPress({required int mapId}) => _on(mapId);

  @override
  Stream<ClusterTapEvent> onClusterTap({required int mapId}) => _on(mapId);

  @override
  Stream<GroundOverlayTapEvent> onGroundOverlayTap({required int mapId}) =>
      _on(mapId);

  @override
  void dispose({required int mapId}) {}
}
