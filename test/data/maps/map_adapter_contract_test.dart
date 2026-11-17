import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    as gp;
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/maps/google_map_adapter.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/maps/osm_map_adapter.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

import '../../helpers/fake_google_maps_platform.dart';

/// PNG transparente de 1x1: los tiles de prueba no salen a la red.
final _transparentPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _OfflineTiles extends TileProvider {
  int requested = 0;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requested++;
    return MemoryImage(_transparentPng);
  }
}

/// Cómo ejercitar cada implementación sin servicios reales.
abstract class _Harness {
  String get name;
  MapProvider get provider;
  MapAdapter build();
  void setUp() {}
  void tearDown() {}

  /// Simula que el usuario toca el mapa en el centro de la vista ([center]).
  Future<void> tapCenter(WidgetTester tester, GeoPoint center);

  /// Ids de los marcadores que el proveedor está mostrando.
  Set<String> markerIds(WidgetTester tester);

  /// Punto hacia donde quedó (o se pidió mover) la cámara.
  Future<GeoPoint> cameraTarget(WidgetTester tester);
}

class _OsmHarness extends _Harness {
  final tiles = _OfflineTiles();

  @override
  String get name => 'OsmMapAdapter';

  @override
  MapProvider get provider => MapProvider.osm;

  @override
  MapAdapter build() => OsmMapAdapter(
    tileUrl: 'https://tiles.example.invalid/{z}/{x}/{y}.png',
    attribution: '© OpenStreetMap contributors',
    tileProvider: tiles,
  );

  @override
  Future<void> tapCenter(WidgetTester tester, GeoPoint center) async {
    await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
    // El toque simple espera a descartar un doble toque (zoom).
    await tester.pump(const Duration(milliseconds: 500));
  }

  @override
  Set<String> markerIds(WidgetTester tester) => {
    for (final m
        in tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers)
      (m.key! as ValueKey<String>).value.replaceFirst('marker-', ''),
  };

  @override
  Future<GeoPoint> cameraTarget(WidgetTester tester) async {
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final c = map.mapController!.camera.center;
    return GeoPoint(c.latitude, c.longitude);
  }
}

class _GoogleHarness extends _Harness {
  late FakeGoogleMapsPlatform platform;
  late gp.GoogleMapsFlutterPlatform previous;
  final loadedKeys = <String>[];

  @override
  String get name => 'GoogleMapAdapter';

  @override
  MapProvider get provider => MapProvider.google;

  @override
  void setUp() {
    previous = gp.GoogleMapsFlutterPlatform.instance;
    platform = FakeGoogleMapsPlatform();
    gp.GoogleMapsFlutterPlatform.instance = platform;
  }

  @override
  void tearDown() => gp.GoogleMapsFlutterPlatform.instance = previous;

  @override
  MapAdapter build() => GoogleMapAdapter(
    apiKey: 'clave-falsa',
    loader: (key) async => loadedKeys.add(key),
  );

  @override
  Future<void> tapCenter(WidgetTester tester, GeoPoint center) async {
    platform.tap(gp.LatLng(center.lat, center.lng));
    await tester.pump();
  }

  @override
  Set<String> markerIds(WidgetTester tester) => {
    for (final m in platform.markers) m.markerId.value,
  };

  @override
  Future<GeoPoint> cameraTarget(WidgetTester tester) async {
    if (platform.cameraUpdates.isEmpty) {
      final t = platform.initialCamera!.target;
      return GeoPoint(t.latitude, t.longitude);
    }
    // ['newLatLngZoom', [lat, lng], zoom]
    final json = platform.cameraUpdates.last.toJson() as List<Object?>;
    final latLng = json[1]! as List<Object?>;
    return GeoPoint(latLng[0]! as double, latLng[1]! as double);
  }
}

void main() {
  const center = GeoPoint(-33.4569, -70.5974);
  const target = GeoPoint(-33.4000, -70.6000);

  for (final harness in <_Harness>[_OsmHarness(), _GoogleHarness()]) {
    group('Contrato de MapAdapter: ${harness.name}', () {
      setUp(harness.setUp);
      tearDown(harness.tearDown);

      Future<MapViewController> pumpMap(
        WidgetTester tester, {
        List<MapMarker> markers = const [],
        ValueChanged<GeoPoint>? onTap,
      }) async {
        final controller = MapViewController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 400,
                height: 300,
                child: harness.build().buildMap(
                  center: center,
                  markers: markers,
                  onTap: onTap,
                  controller: controller,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        return controller;
      }

      test('declara su proveedor y una atribución', () {
        final adapter = harness.build();
        expect(adapter.provider, harness.provider);
        expect(adapter.attribution, isNotEmpty);
      });

      testWidgets('se centra en el punto inicial', (tester) async {
        await pumpMap(tester);
        final cam = await harness.cameraTarget(tester);
        expect(cam.lat, closeTo(center.lat, 1e-6));
        expect(cam.lng, closeTo(center.lng, 1e-6));
      });

      testWidgets('muestra los marcadores recibidos', (tester) async {
        await pumpMap(
          tester,
          markers: const [
            MapMarker(id: 'casa', point: center, label: 'Casa'),
            MapMarker(id: 'vet', point: target),
          ],
        );
        expect(harness.markerIds(tester), {'casa', 'vet'});
      });

      testWidgets('un toque entrega el punto como GeoPoint', (tester) async {
        GeoPoint? tapped;
        await pumpMap(tester, onTap: (p) => tapped = p);
        await harness.tapCenter(tester, center);
        expect(tapped, isNotNull);
        expect(tapped!.lat, closeTo(center.lat, 1e-3));
        expect(tapped!.lng, closeTo(center.lng, 1e-3));
      });

      testWidgets('sin onTap, tocar no falla', (tester) async {
        await pumpMap(tester);
        await harness.tapCenter(tester, center);
        expect(tester.takeException(), isNull);
      });

      testWidgets('el controlador mueve la cámara', (tester) async {
        final controller = await pumpMap(tester);
        expect(controller.isAttached, isTrue);
        await controller.animateTo(target, zoom: 17);
        await tester.pump();
        final cam = await harness.cameraTarget(tester);
        expect(cam.lat, closeTo(target.lat, 1e-6));
        expect(cam.lng, closeTo(target.lng, 1e-6));
      });

      testWidgets('al desmontar, el controlador queda suelto', (tester) async {
        final controller = await pumpMap(tester);
        await tester.pumpWidget(const SizedBox());
        expect(controller.isAttached, isFalse);
        // No falla aunque el mapa ya no exista.
        await controller.animateTo(target);
      });
    });
  }

  group('Específico de cada proveedor', () {
    testWidgets('OSM pide los tiles al proveedor inyectado (sin red)', (
      tester,
    ) async {
      final harness = _OsmHarness();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 300,
            height: 300,
            child: harness.build().buildMap(center: center),
          ),
        ),
      );
      await tester.pump();
      expect(harness.tiles.requested, greaterThan(0));
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    });

    testWidgets('Google carga el SDK con la clave configurada', (tester) async {
      final harness = _GoogleHarness()..setUp();
      addTearDown(harness.tearDown);
      await tester.pumpWidget(
        MaterialApp(home: harness.build().buildMap(center: center)),
      );
      await tester.pump();
      expect(harness.loadedKeys, ['clave-falsa']);
    });

    testWidgets('si el SDK de Google no carga, muestra un aviso', (
      tester,
    ) async {
      final adapter = GoogleMapAdapter(
        apiKey: 'x',
        loader: (_) => Future.error(StateError('sin red')),
      );
      await tester.pumpWidget(
        MaterialApp(home: adapter.buildMap(center: center)),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('No se pudo cargar el mapa.'), findsOneWidget);
    });
  });
}
