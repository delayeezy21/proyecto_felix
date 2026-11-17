import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

/// Geocoding API de Google (REST). Solo en Android: en Web se usa Nominatim
/// (ver `Env.effectiveGeocodingProvider`). La clave va por `--dart-define`
/// y debe estar restringida por app en Google Cloud.
class GoogleGeocodingAdapter implements GeocodingAdapter {
  new({required this._client, required this._apiKey});

  final http.Client _client;
  final String _apiKey;

  static const _base = 'https://maps.googleapis.com/maps/api/geocode/json';

  @override
  MapProvider get provider => MapProvider.google;

  @override
  Future<List<GeocodingResult>> search(String query) async {
    if (normalizeQuery(query).length < minQueryLength) return const [];
    final results = await _get({
      'address': query.trim(),
      'components': 'country:CL',
    });
    return [for (final r in results.take(5)) ?_parse(r)];
  }

  @override
  Future<GeocodingResult?> reverse(GeoPoint point) async {
    final results = await _get({
      'latlng':
          '${point.lat.toStringAsFixed(6)},${point.lng.toStringAsFixed(6)}',
    });
    return results.isEmpty ? null : _parse(results.first);
  }

  Future<List<Map<String, dynamic>>> _get(Map<String, String> params) async {
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse(_base).replace(
              queryParameters: {
                ...params,
                'language': 'es',
                'region': 'cl',
                'key': _apiKey,
              },
            ),
          )
          .timeout(const Duration(seconds: 8));
    } on Object {
      throw const GeocodingFailure();
    }
    if (response.statusCode != 200) throw const GeocodingFailure();
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const GeocodingFailure();
    }
    if (json is! Map<String, dynamic>) throw const GeocodingFailure();
    switch (json['status']) {
      case 'OK':
        return (json['results'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
      case 'ZERO_RESULTS':
        return const [];
      default:
        throw const GeocodingFailure();
    }
  }

  static GeocodingResult? _parse(Map<String, dynamic> r) {
    final location = (r['geometry'] as Map?)?['location'] as Map?;
    final lat = (location?['lat'] as num?)?.toDouble();
    final lng = (location?['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    String? route;
    String? number;
    String? commune;
    for (final c
        in (r['address_components'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()) {
      final types = (c['types'] as List? ?? const []).cast<String>();
      final name = c['long_name'] as String?;
      if (types.contains('route')) route = name;
      if (types.contains('street_number')) number = name;
      // En Chile la comuna es administrative_area_level_3 (o locality).
      if (types.contains('administrative_area_level_3')) commune = name;
      if (types.contains('locality')) commune ??= name;
    }
    final formatted = (r['formatted_address'] as String?) ?? '';
    final label = route != null
        ? (number == null ? route : '$route $number')
        : formatted.split(',').first.trim();
    if (label.isEmpty) return null;
    return GeocodingResult(
      label: label,
      point: GeoPoint(lat, lng),
      communeName: commune,
    );
  }
}
