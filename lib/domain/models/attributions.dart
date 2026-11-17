import 'package:flutter/foundation.dart' show immutable;

/// Atribución de datos de terceros (ver docs/licencias.md).
@immutable
class DataAttribution {
  const new({
    required this.title,
    required this.usage,
    required this.source,
    required this.license,
    required this.licenseUrl,
  });

  final String title;
  final String usage;
  final String source;
  final String license;
  final String licenseUrl;
}

/// Lista mostrada en "Acerca de / licencias". Mantener igual a
/// docs/licencias.md.
const dataAttributions = [
  DataAttribution(
    title: 'Límites comunales de Chile',
    usage: 'Validar que la dirección esté en su comuna y en Chile.',
    source:
        'geoBoundaries (gbOpen CHL ADM3), con origen en BCN y OCHA ROLAC '
        '(2020). Adaptado por Felix: simplificado y con nombres corregidos.',
    license: 'CC BY 3.0 IGO',
    licenseUrl: 'https://creativecommons.org/licenses/by/3.0/igo/',
  ),
  DataAttribution(
    title: 'Mapa base OpenStreetMap',
    usage: 'Mapas de la app.',
    source: '© colaboradores de OpenStreetMap',
    license: 'ODbL 1.0',
    licenseUrl: 'https://opendatacommons.org/licenses/odbl/1-0/',
  ),
  DataAttribution(
    title: 'Geocoding Nominatim',
    usage: 'Búsqueda de direcciones.',
    source: '© colaboradores de OpenStreetMap',
    license: 'ODbL 1.0',
    licenseUrl: 'https://opendatacommons.org/licenses/odbl/1-0/',
  ),
];
