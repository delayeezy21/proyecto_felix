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
  );

  final String supabaseUrl;
  final String supabasePublishableKey;
  final MapProvider mapProvider;
  final String mapsApiKey;

  /// Muestra "Continuar con Google". Debe coincidir con
  /// `[auth.external.google] enabled` en Supabase; si no, el login falla con
  /// "provider is not enabled".
  final bool googleAuthEnabled;

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
