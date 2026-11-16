/// Proveedor de mapas configurable (ver docs/arquitectura.md §3).
enum MapProvider {
  google,
  osm;

  static MapProvider parse(String value) =>
      switch (value.trim().toLowerCase()) {
        'google' => MapProvider.google,
        _ => MapProvider.osm,
      };
}

/// Plataformas que distinguen el proveedor de mapas efectivo.
enum AppPlatform { android, ios, web, windows, other }

/// Configuración de la app leída de `--dart-define-from-file=.env`.
///
/// Solo contiene valores que pueden ir dentro del cliente. Los secretos de
/// servidor nunca llegan aquí.
class Env {
  const new({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.mapProvider,
    required this.mapsApiKey,
  });

  factory fromEnvironment() => Env(
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: const String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
    ),
    mapProvider: MapProvider.parse(
      const String.fromEnvironment('MAP_PROVIDER', defaultValue: 'osm'),
    ),
    mapsApiKey: const String.fromEnvironment('MAPS_API_KEY'),
  );

  final String supabaseUrl;
  final String supabasePublishableKey;
  final MapProvider mapProvider;
  final String mapsApiKey;

  bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;

  /// Proveedor de mapas real según la plataforma.
  ///
  /// Windows siempre usa OSM (`google_maps_flutter` no soporta Windows), y
  /// Google sin API key cae a OSM.
  MapProvider effectiveMapProvider(AppPlatform platform) {
    if (platform == AppPlatform.windows || platform == AppPlatform.other) {
      return MapProvider.osm;
    }
    if (mapProvider == MapProvider.google && mapsApiKey.isEmpty) {
      return MapProvider.osm;
    }
    return mapProvider;
  }
}
