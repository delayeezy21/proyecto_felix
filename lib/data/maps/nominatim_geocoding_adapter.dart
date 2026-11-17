import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

/// Geocoding con Nominatim (OSM).
///
/// Política de uso del servidor público: máximo 1 petición por segundo, sin
/// uso masivo, con una identificación de la app y con atribución. Por eso:
/// * se espera al menos [minInterval] entre peticiones (cola serial);
/// * se usa siempre detrás de [CachingGeocodingAdapter] y la UI aplica
///   debounce;
/// * el User-Agent es genérico de la app, sin datos personales. En Web el
///   navegador no permite fijarlo y se identifica con el Referer.
class NominatimGeocodingAdapter implements GeocodingAdapter {
  new({
    required this._client,
    String baseUrl = Env.defaultNominatimUrl,
    this.minInterval = const Duration(milliseconds: 1100),
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    bool? isWeb,
  }) : _baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed,
       _isWeb = isWeb ?? kIsWeb;

  final http.Client _client;
  final String _baseUrl;
  final Duration minInterval;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final bool _isWeb;

  /// Identificación genérica de la app (sin correo ni datos del usuario).
  static const userAgent =
      'ProyectoFelix/0.1 (cl.proyectofelix.proyecto_felix)';

  DateTime? _last;
  Future<void> _queue = Future.value();

  @override
  MapProvider get provider => MapProvider.osm;

  @override
  Future<List<GeocodingResult>> search(String query) async {
    if (normalizeQuery(query).length < minQueryLength) return const [];
    final json = await _get('/search', {
      'q': query.trim(),
      'format': 'jsonv2',
      'countrycodes': 'cl',
      'limit': '5',
      'addressdetails': '1',
      'accept-language': 'es',
    });
    if (json is! List) return const [];
    return [
      for (final item in json.whereType<Map<String, dynamic>>()) ?_parse(item),
    ];
  }

  @override
  Future<GeocodingResult?> reverse(GeoPoint point) async {
    final json = await _get('/reverse', {
      'lat': point.lat.toStringAsFixed(6),
      'lon': point.lng.toStringAsFixed(6),
      'format': 'jsonv2',
      'zoom': '18',
      'addressdetails': '1',
      'accept-language': 'es',
    });
    if (json is! Map<String, dynamic> || json.containsKey('error')) {
      return null;
    }
    return _parse(json);
  }

  Future<Object?> _get(String path, Map<String, String> params) {
    final done = Completer<Object?>();
    // Cola serial: cada petición espera a la anterior y respeta el intervalo.
    _queue = _queue.then((_) async {
      try {
        final last = _last;
        if (last != null) {
          final wait = minInterval - _now().difference(last);
          if (wait > Duration.zero) await _delay(wait);
        }
        _last = _now();
        final response = await _client
            .get(
              Uri.parse('$_baseUrl$path').replace(queryParameters: params),
              headers: {if (!_isWeb) 'User-Agent': userAgent},
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode != 200) throw const GeocodingFailure();
        done.complete(jsonDecode(utf8.decode(response.bodyBytes)));
      } on GeocodingFailure catch (e) {
        done.completeError(e);
      } on Object {
        done.completeError(const GeocodingFailure());
      }
    });
    return done.future;
  }

  static GeocodingResult? _parse(Map<String, dynamic> item) {
    final lat = double.tryParse('${item['lat']}');
    final lng = double.tryParse('${item['lon']}');
    if (lat == null || lng == null) return null;
    final address = item['address'];
    String? street;
    String? commune;
    if (address is Map<String, dynamic>) {
      final road = address['road'] as String?;
      final number = address['house_number'] as String?;
      if (road != null) street = number == null ? road : '$road $number';
      commune =
          (address['city'] ??
                  address['town'] ??
                  address['village'] ??
                  address['municipality'] ??
                  address['suburb'])
              as String?;
    }
    final display = (item['display_name'] as String?) ?? '';
    final label =
        street ?? display.split(',').take(2).map((s) => s.trim()).join(', ');
    if (label.isEmpty) return null;
    return GeocodingResult(
      label: label,
      point: GeoPoint(lat, lng),
      communeName: commune,
    );
  }
}
