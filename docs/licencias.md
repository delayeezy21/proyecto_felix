# Licencias de datos de terceros

| Datos | Uso en Felix | Fuente | Licencia |
|---|---|---|---|
| Límites comunales de Chile (simplificados) | Tabla `commune_boundaries`: valida que el punto de una dirección esté en su comuna y en Chile | geoBoundaries gbOpen CHL ADM3 (commit `9469f09`), con origen en BCN y OCHA ROLAC (2020). La adaptación (simplificación con PostGIS y correcciones de nombres) está descrita en la migración `20261117165218_commune_boundaries.sql` | [CC BY 3.0 IGO](https://creativecommons.org/licenses/by/3.0/igo/) |
| Mapa base OpenStreetMap | Tiles del mapa | © colaboradores de OpenStreetMap | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) |
| Geocoding Nominatim | Búsqueda de direcciones | © colaboradores de OpenStreetMap | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) |

Pendiente (QA-F4-07): una pantalla "Acerca de / licencias" en la app con esta misma atribución, junto con la de OSM.
