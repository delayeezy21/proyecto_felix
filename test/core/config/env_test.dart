import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/core/config/env.dart';

Env _env({
  String url = '',
  String key = '',
  MapProvider map = MapProvider.osm,
  String mapsKey = '',
}) => Env(
  supabaseUrl: url,
  supabasePublishableKey: key,
  mapProvider: map,
  mapsApiKey: mapsKey,
);

void main() {
  group('MapProvider.parse', () {
    test('reconoce google sin importar mayúsculas ni espacios', () {
      expect(MapProvider.parse(' Google '), MapProvider.google);
    });

    test('cualquier otro valor cae a osm', () {
      expect(MapProvider.parse('osm'), MapProvider.osm);
      expect(MapProvider.parse(''), MapProvider.osm);
      expect(MapProvider.parse('mapbox'), MapProvider.osm);
    });
  });

  group('Env.isSupabaseConfigured', () {
    test('requiere url y clave publicable', () {
      expect(_env().isSupabaseConfigured, isFalse);
      expect(_env(url: 'http://x').isSupabaseConfigured, isFalse);
      expect(_env(key: 'k').isSupabaseConfigured, isFalse);
      expect(_env(url: 'http://x', key: 'k').isSupabaseConfigured, isTrue);
    });
  });

  group('Env.effectiveMapProvider', () {
    final google = _env(map: MapProvider.google, mapsKey: 'abc');

    test('Windows siempre usa OSM', () {
      expect(google.effectiveMapProvider(AppPlatform.windows), MapProvider.osm);
    });

    test('Android y Web usan Google si hay API key', () {
      for (final p in [AppPlatform.android, AppPlatform.web]) {
        expect(google.effectiveMapProvider(p), MapProvider.google);
      }
    });

    test('iOS usa OSM hasta configurar la clave nativa en un Mac', () {
      expect(google.effectiveMapProvider(AppPlatform.ios), MapProvider.osm);
    });

    test(
      'el geocoding no reutiliza la clave del mapa (Android la rechaza)',
      () {
        // Con solo MAPS_API_KEY, el geocoding es Nominatim en todas partes.
        for (final p in AppPlatform.values) {
          expect(google.effectiveGeocodingProvider(p), MapProvider.osm);
        }
      },
    );

    test('Google Geocoding solo en Android y con su propia clave', () {
      const env = Env(
        supabaseUrl: '',
        supabasePublishableKey: '',
        mapProvider: MapProvider.google,
        mapsApiKey: 'abc',
        geocodingApiKey: 'geo',
      );
      expect(
        env.effectiveGeocodingProvider(AppPlatform.android),
        MapProvider.google,
      );
      expect(env.effectiveGeocodingProvider(AppPlatform.web), MapProvider.osm);
      expect(
        env.effectiveGeocodingProvider(AppPlatform.windows),
        MapProvider.osm,
      );
    });

    test('los tiles y Nominatim tienen valores por defecto', () {
      expect(google.osmTileUrl, contains('{z}/{x}/{y}'));
      expect(google.nominatimUrl, startsWith('https://'));
    });

    test('Google sin API key cae a OSM', () {
      final sinKey = _env(map: MapProvider.google);
      expect(sinKey.effectiveMapProvider(AppPlatform.android), MapProvider.osm);
    });

    test('OSM configurado se respeta en todas las plataformas', () {
      for (final p in AppPlatform.values) {
        expect(_env().effectiveMapProvider(p), MapProvider.osm);
      }
    });
  });

  group('Env.isLocalBackend', () {
    test('localhost, 127.0.0.1 y redes privadas son locales', () {
      for (final url in [
        'http://127.0.0.1:54321',
        'http://localhost:54321',
        'http://192.168.100.5:54321',
        'http://10.0.0.8:54321',
        'http://172.20.1.2:54321',
      ]) {
        expect(_env(url: url).isLocalBackend, isTrue, reason: url);
      }
    });

    test('un proyecto en la nube no es local', () {
      expect(_env(url: 'https://abc.supabase.co').isLocalBackend, isFalse);
      expect(_env(url: 'http://172.32.0.1:54321').isLocalBackend, isFalse);
    });
  });
}
