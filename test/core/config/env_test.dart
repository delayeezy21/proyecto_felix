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

    test('Android, iOS y Web usan Google si hay API key', () {
      for (final p in [AppPlatform.android, AppPlatform.ios, AppPlatform.web]) {
        expect(google.effectiveMapProvider(p), MapProvider.google);
      }
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
