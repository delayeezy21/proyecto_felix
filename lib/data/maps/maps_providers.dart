import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/google_geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/google_map_adapter.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/maps/nominatim_geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/osm_map_adapter.dart';

/// Plataforma actual (se sobrescribe en los tests).
final appPlatformProvider = Provider<AppPlatform>((ref) {
  if (kIsWeb) return AppPlatform.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => AppPlatform.android,
    TargetPlatform.iOS => AppPlatform.ios,
    TargetPlatform.windows => AppPlatform.windows,
    _ => AppPlatform.other,
  };
});

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Mapa según `MAP_PROVIDER`, la API key y la plataforma (Windows: OSM).
final mapAdapterProvider = Provider<MapAdapter>((ref) {
  final env = ref.watch(envProvider);
  return switch (env.effectiveMapProvider(ref.watch(appPlatformProvider))) {
    MapProvider.google => GoogleMapAdapter(apiKey: env.mapsApiKey),
    MapProvider.osm => OsmMapAdapter(
      tileUrl: env.osmTileUrl,
      attribution: env.osmTileAttribution,
    ),
  };
});

/// Geocoding con caché (una instancia por app: la caché y la cola de
/// Nominatim se comparten entre pantallas).
final geocodingAdapterProvider = Provider<GeocodingAdapter>((ref) {
  final env = ref.watch(envProvider);
  final client = ref.watch(httpClientProvider);
  final inner = switch (env.effectiveGeocodingProvider(
    ref.watch(appPlatformProvider),
  )) {
    MapProvider.google => GoogleGeocodingAdapter(
      client: client,
      apiKey: env.geocodingApiKey,
    ),
    MapProvider.osm => NominatimGeocodingAdapter(
      client: client,
      baseUrl: env.nominatimUrl,
    ),
  };
  return CachingGeocodingAdapter(inner);
});
