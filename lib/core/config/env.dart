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
    this.googleAuthEnabled = false,
    this.osmTileUrl = defaultOsmTileUrl,
    this.osmTileAttribution = defaultOsmAttribution,
    this.nominatimUrl = defaultNominatimUrl,
    this.geocodingApiKey = '',
  });

  factory fromEnvironment() => Env(
    googleAuthEnabled: _isTrue(
      const String.fromEnvironment('GOOGLE_AUTH_ENABLED'),
    ),
    supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
    supabasePublishableKey: const String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
    ),
    mapProvider: MapProvider.parse(
      const String.fromEnvironment('MAP_PROVIDER', defaultValue: 'osm'),
    ),
    mapsApiKey: const String.fromEnvironment('MAPS_API_KEY'),
    osmTileUrl: _orDefault(
      const String.fromEnvironment('OSM_TILE_URL'),
      defaultOsmTileUrl,
    ),
    osmTileAttribution: _orDefault(
      const String.fromEnvironment('OSM_TILE_ATTRIBUTION'),
      defaultOsmAttribution,
    ),
    nominatimUrl: _orDefault(
      const String.fromEnvironment('NOMINATIM_URL'),
      defaultNominatimUrl,
    ),
    // El analizador lo ve vacío sin --dart-define; en ejecución no lo es.
    // ignore: avoid_redundant_argument_values
    geocodingApiKey: const String.fromEnvironment('GOOGLE_GEOCODING_API_KEY'),
  );

  /// Tiles públicos de OSM: sirven para desarrollo y demos, NO para tráfico
  /// alto (política de uso de la OSMF). En producción se usa Stadia o
  /// MapTiler vía `OSM_TILE_URL`.
  static const defaultOsmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const defaultOsmAttribution = '© OpenStreetMap contributors';
  static const defaultNominatimUrl = 'https://nominatim.openstreetmap.org';

  final String supabaseUrl;
  final String supabasePublishableKey;
  final MapProvider mapProvider;
  final String mapsApiKey;

  /// Muestra "Continuar con Google". Debe coincidir con
  /// `[auth.external.google] enabled` en Supabase; si no, el login falla con
  /// "provider is not enabled".
  final bool googleAuthEnabled;

  /// Plantilla de tiles raster (`{z}/{x}/{y}`) del proveedor OSM.
  final String osmTileUrl;

  /// Atribución que exige el proveedor de tiles.
  final String osmTileAttribution;

  /// Servidor Nominatim (geocoding de OSM). El público admite 1 req/s máximo.
  final String nominatimUrl;

  /// Clave de la API REST de Geocoding de Google (solo Android). Distinta de
  /// [mapsApiKey]; ver [effectiveGeocodingProvider].
  final String geocodingApiKey;

  static String _orDefault(String value, String fallback) =>
      value.trim().isEmpty ? fallback : value.trim();

  static bool _isTrue(String value) => value.trim().toLowerCase() == 'true';

  /// Backend local (Supabase CLI): los correos no salen a internet, quedan en
  /// Mailpit. Se usa para mostrar ayudas de desarrollo.
  bool get isLocalBackend {
    final host = Uri.tryParse(supabaseUrl)?.host ?? '';
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        _privateClassB.hasMatch(host);
  }

  /// 172.16.0.0 – 172.31.255.255 (red privada clase B).
  static final _privateClassB = RegExp(r'^172\.(1[6-9]|2\d|3[01])\.');

  bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty;

  /// Proveedor de mapas real según la plataforma.
  ///
  /// Windows siempre usa OSM (`google_maps_flutter` no soporta Windows), y
  /// Google sin API key cae a OSM. iOS también usa OSM hasta probar la clave
  /// nativa en un Mac (falta `GMSServices.provideAPIKey` en el AppDelegate).
  MapProvider effectiveMapProvider(AppPlatform platform) {
    if (platform == AppPlatform.windows ||
        platform == AppPlatform.ios ||
        platform == AppPlatform.other) {
      return MapProvider.osm;
    }
    if (mapProvider == MapProvider.google && mapsApiKey.isEmpty) {
      return MapProvider.osm;
    }
    return mapProvider;
  }

  /// Proveedor de geocoding: Google solo en Android y solo con una clave
  /// propia ([geocodingApiKey]); si no, Nominatim.
  ///
  /// * Web: la API REST de Geocoding de Google no admite CORS.
  /// * Android: la API REST rechaza (REQUEST_DENIED) una clave restringida a
  ///   la app si la petición no trae `X-Android-Package` y `X-Android-Cert`
  ///   (QA-9e912e5). Por eso no se reutiliza la clave del mapa: hace falta
  ///   una clave restringida por API (solo Geocoding API) y con cuota.
  MapProvider effectiveGeocodingProvider(AppPlatform platform) =>
      platform == AppPlatform.android && geocodingApiKey.isNotEmpty
      ? MapProvider.google
      : MapProvider.osm;
}
