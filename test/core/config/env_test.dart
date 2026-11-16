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
}
