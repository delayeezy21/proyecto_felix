import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/google_geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/nominatim_geocoding_adapter.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

/// Respuestas sintéticas con el formato de cada proveedor (sin red).
abstract class _Harness {
  final requests = <http.Request>[];

  /// 'ok', 'empty', 'http500', 'invalid' o 'network'.
  String mode = 'ok';

  String get name;
  MapProvider get provider;

  GeocodingAdapter build(http.Client client);

  String searchBody();
  String reverseBody();
  String emptyBody();

  GeocodingAdapter create() => build(
    MockClient((request) async {
      requests.add(request);
      switch (mode) {
        case 'network':
          throw http.ClientException('sin red');
        case 'http500':
          return http.Response('error', 500);
        case 'invalid':
          return http.Response('<html>no es json</html>', 200);
        case 'empty':
          return http.Response.bytes(utf8.encode(emptyBody()), 200);
      }
      final body =
          request.url.path.contains('reverse') ||
              request.url.queryParameters.containsKey('latlng')
          ? reverseBody()
          : searchBody();
      return http.Response.bytes(utf8.encode(body), 200);
    }),
  );
}

class _NominatimHarness extends _Harness {
  final delays = <Duration>[];
  DateTime clock = DateTime(2026, 11, 17, 12);

  @override
  String get name => 'NominatimGeocodingAdapter';

  @override
  MapProvider get provider => MapProvider.osm;

  @override
  GeocodingAdapter build(http.Client client) => NominatimGeocodingAdapter(
    client: client,
    baseUrl: 'https://nominatim.example.invalid/',
    now: () => clock,
    delay: (d) async => delays.add(d),
    isWeb: false,
  );

  @override
  String searchBody() => jsonEncode([
    {
      'lat': '-33.4569',
      'lon': '-70.5974',
      'display_name': 'Avenida Ficticia, Ñuñoa, Santiago, Chile',
      'address': {
        'road': 'Avenida Ficticia',
        'house_number': '123',
        'city': 'Ñuñoa',
      },
    },
    {
      'lat': '-33.4400',
      'lon': '-70.6500',
      'display_name': 'Calle Inventada, Santiago, Chile',
    },
  ]);

  @override
  String reverseBody() => jsonEncode({
    'lat': '-33.4569',
    'lon': '-70.5974',
    'display_name': 'Avenida Ficticia 123, Ñuñoa, Chile',
    'address': {'road': 'Avenida Ficticia', 'house_number': '123'},
  });

  @override
  String emptyBody() => '[]';
}

class _GoogleHarness extends _Harness {
  @override
  String get name => 'GoogleGeocodingAdapter';

  @override
  MapProvider get provider => MapProvider.google;

  @override
  GeocodingAdapter build(http.Client client) =>
      GoogleGeocodingAdapter(client: client, apiKey: 'clave-falsa');

  Map<String, Object?> _result(
    double lat,
    double lng, {
    String? route,
    String? number,
  }) => {
    'formatted_address': '${route ?? 'Lugar'} ${number ?? ''}, Ñuñoa, Chile',
    'geometry': {
      'location': {'lat': lat, 'lng': lng},
    },
    'address_components': [
      if (number != null)
        {
          'long_name': number,
          'types': ['street_number'],
        },
      if (route != null)
        {
          'long_name': route,
          'types': ['route'],
        },
      {
        'long_name': 'Ñuñoa',
        'types': ['administrative_area_level_3', 'political'],
      },
    ],
  };

  @override
  String searchBody() => jsonEncode({
    'status': 'OK',
    'results': [
      _result(-33.4569, -70.5974, route: 'Avenida Ficticia', number: '123'),
      _result(-33.44, -70.65),
    ],
  });

  @override
  String reverseBody() => jsonEncode({
    'status': 'OK',
    'results': [
      _result(-33.4569, -70.5974, route: 'Avenida Ficticia', number: '123'),
    ],
  });

  @override
  String emptyBody() =>
      jsonEncode({'status': 'ZERO_RESULTS', 'results': <Object>[]});
}

void main() {
  for (final make in <_Harness Function()>[
    _NominatimHarness.new,
    _GoogleHarness.new,
  ]) {
    final name = make().name;
    group('Contrato de GeocodingAdapter: $name', () {
      late _Harness h;
      late GeocodingAdapter adapter;

      setUp(() {
        h = make();
        adapter = h.create();
      });

      test('declara su proveedor', () {
        expect(adapter.provider, h.provider);
      });

      test('busca y devuelve resultados en Chile con etiqueta', () async {
        final r = await adapter.search('Avenida Ficticia 123');
        expect(r, isNotEmpty);
        expect(r.length, lessThanOrEqualTo(5));
        expect(r.first.label, 'Avenida Ficticia 123');
        expect(r.first.point.lat, closeTo(-33.4569, 1e-6));
        expect(r.first.point.lng, closeTo(-70.5974, 1e-6));
        expect(r.every((x) => x.point.isInChile && x.label.isNotEmpty), isTrue);
        expect(r.first.communeName, 'Ñuñoa');
      });

      test('la búsqueda se restringe a Chile y en español', () async {
        await adapter.search('Avenida Ficticia');
        final q = h.requests.single.url.queryParameters;
        final country = q['countrycodes'] ?? q['components'];
        expect(country?.toLowerCase(), anyOf('cl', 'country:cl'));
        expect(q['accept-language'] ?? q['language'], 'es');
      });

      test('consultas de menos de 3 letras no llaman al proveedor', () async {
        expect(await adapter.search(' ab '), isEmpty);
        expect(h.requests, isEmpty);
      });

      test('sin coincidencias devuelve una lista vacía', () async {
        h.mode = 'empty';
        expect(await adapter.search('zzzz inexistente'), isEmpty);
      });

      test('geocodificación inversa devuelve la dirección', () async {
        final r = await adapter.reverse(const GeoPoint(-33.4569, -70.5974));
        expect(r, isNotNull);
        expect(r!.label, 'Avenida Ficticia 123');
      });

      for (final mode in ['http500', 'invalid', 'network']) {
        test('un error ($mode) se informa como GeocodingFailure', () async {
          h.mode = mode;
          await expectLater(
            adapter.search('Avenida Ficticia'),
            throwsA(isA<GeocodingFailure>()),
          );
        });
      }

      test(
        'la petición solo lleva la consulta (sin datos personales)',
        () async {
          await adapter.search('Avenida Ficticia 123');
          final req = h.requests.single;
          final allowed = {
            'q',
            'address',
            'format',
            'countrycodes',
            'components',
            'limit',
            'addressdetails',
            'accept-language',
            'language',
            'region',
            'key',
          };
          expect(
            req.url.queryParameters.keys.toSet().difference(allowed),
            isEmpty,
          );
          expect(req.url.toString(), isNot(contains('@')));
          expect(
            req.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('cookie')),
          );
        },
      );
    });
  }

  group('Nominatim: política de uso', () {
    test('envía un User-Agent genérico de la app (fuera de Web)', () async {
      final h = _NominatimHarness();
      await h.create().search('Avenida Ficticia');
      final ua = h.requests.single.headers['User-Agent'];
      expect(ua, NominatimGeocodingAdapter.userAgent);
      expect(ua, isNot(contains('@')));
    });

    test('en Web no fija User-Agent (el navegador no lo permite)', () async {
      final requests = <http.Request>[];
      final adapter = NominatimGeocodingAdapter(
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('[]', 200);
        }),
        isWeb: true,
      );
      await adapter.search('Avenida Ficticia');
      expect(requests.single.headers.containsKey('User-Agent'), isFalse);
    });

    test('espera al menos 1 s entre peticiones', () async {
      final h = _NominatimHarness();
      final adapter = h.create();
      await adapter.search('Avenida Uno');
      h.clock = h.clock.add(const Duration(milliseconds: 300));
      await adapter.search('Avenida Dos');
      expect(h.delays, hasLength(1));
      expect(h.delays.single, const Duration(milliseconds: 800));
      expect(h.requests, hasLength(2));
    });

    test('no espera si ya pasó el intervalo', () async {
      final h = _NominatimHarness();
      final adapter = h.create();
      await adapter.search('Avenida Uno');
      h.clock = h.clock.add(const Duration(seconds: 2));
      await adapter.search('Avenida Dos');
      expect(h.delays, isEmpty);
    });

    test('usa la URL configurada sin duplicar la barra', () async {
      final h = _NominatimHarness();
      await h.create().search('Avenida Ficticia');
      expect(
        h.requests.single.url.toString(),
        startsWith('https://nominatim.example.invalid/search?'),
      );
    });
  });

  group('CachingGeocodingAdapter', () {
    late _NominatimHarness h;
    late GeocodingAdapter cached;

    setUp(() {
      h = _NominatimHarness();
      cached = CachingGeocodingAdapter(h.create(), maxEntries: 2);
    });

    test('repite una búsqueda desde la caché (normalizada)', () async {
      await cached.search('Avenida  Ficticia');
      await cached.search(' avenida ficticia ');
      expect(h.requests, hasLength(1));
    });

    test('deduplica peticiones simultáneas', () async {
      await Future.wait([
        cached.search('Avenida Ficticia'),
        cached.search('Avenida Ficticia'),
      ]);
      expect(h.requests, hasLength(1));
    });

    test('la geocodificación inversa se cachea por punto (~11 m)', () async {
      await cached.reverse(const GeoPoint(-33.456901, -70.597401));
      await cached.reverse(const GeoPoint(-33.456899, -70.597399));
      expect(h.requests, hasLength(1));
    });

    test('descarta la entrada menos usada al superar el tope', () async {
      await cached.search('Calle Uno');
      await cached.search('Calle Dos');
      await cached.search('Calle Uno'); // la usa: queda como reciente
      await cached.search('Calle Tres'); // expulsa a "Calle Dos"
      await cached.search('Calle Uno');
      expect(h.requests, hasLength(3));
      await cached.search('Calle Dos');
      expect(h.requests, hasLength(4));
    });

    test('no cachea errores', () async {
      h.mode = 'http500';
      await expectLater(
        cached.search('Avenida Ficticia'),
        throwsA(isA<GeocodingFailure>()),
      );
      h.mode = 'ok';
      expect(await cached.search('Avenida Ficticia'), isNotEmpty);
      expect(h.requests, hasLength(2));
    });
  });
}
