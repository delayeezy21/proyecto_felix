import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/theme/app_theme.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/maps/maps_providers.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/urgent/view_models/urgent_providers.dart';

/// Dueño: mapa con el vet en camino (vía `MapAdapter`; OSM en Windows).
/// Mientras este widget está montado se escucha el canal `visit:{id}`; al
/// pasar a "llegó" o cancelada deja de construirse y se sale del canal.
class OwnerLiveMap extends ConsumerStatefulWidget {
  const new({required this.visitId, super.key});

  final String visitId;

  @override
  ConsumerState<OwnerLiveMap> createState() => _OwnerLiveMapState();
}

class _OwnerLiveMapState extends ConsumerState<OwnerLiveMap> {
  final _controller = MapViewController();

  @override
  Widget build(BuildContext context) {
    final provider = ownerLiveLocationProvider(widget.visitId);
    ref.listen(provider, (_, next) {
      if (next.value case final loc?) {
        unawaited(_controller.animateTo(loc.point, zoom: 15));
      }
    });
    final live = ref.watch(provider);
    final loc = live.value;
    final map = ref.watch(mapAdapterProvider);
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Ubicación del veterinario', style: t.titleSmall),
        const SizedBox(height: 8),
        Semantics(
          label: loc == null
              ? 'Mapa. Esperando la ubicación del veterinario.'
              : 'Mapa con la ubicación del veterinario en camino.',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: SizedBox(
              key: const Key('live-map'),
              height: 240,
              child: map.buildMap(
                center: loc?.point ?? GeoPoint.santiago,
                zoom: loc == null ? 11 : 15,
                controller: _controller,
                markers: [
                  if (loc != null)
                    MapMarker(
                      id: 'vet',
                      point: loc.point,
                      label: 'Veterinario en camino',
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          switch (live) {
            AsyncError() when loc == null =>
              'No se pudo conectar la ubicación en vivo. La visita sigue en '
                  'curso.',
            _ when loc == null => 'Esperando la ubicación del veterinario…',
            _ => 'Actualizada a las ${_hms(loc.at)}.',
          },
          key: const Key('live-map-status'),
          style: t.bodySmall,
        ),
      ],
    );
  }

  static String _hms(DateTime d) =>
      '${formatHour(d)}:${d.second.toString().padLeft(2, '0')}';
}

/// Vet: comparte su posición cada 5 s mientras la visita está "en camino".
/// Al desmontarse (llegó o canceló) avisa al dueño y sale del canal.
class VetLiveSharingBanner extends ConsumerWidget {
  const new({required this.visitId, super.key});

  final String visitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final share = ref.watch(vetLiveSharingProvider(visitId));
    return InfoBanner(
      key: Key('vet-live-$visitId'),
      tone: share.noPosition || share.failed
          ? BannerTone.warning
          : BannerTone.info,
      icon: Icons.near_me_outlined,
      message: share.noPosition
          ? 'No podemos leer tu ubicación: activa el GPS o el permiso de '
                'ubicación para que el dueño te vea llegar.'
          : share.failed
          ? 'No se pudo enviar tu ubicación. Reintentamos en unos segundos.'
          : 'Compartes tu ubicación con el dueño mientras vas en camino. '
                'Mantén esta pantalla abierta. Se deja de compartir al '
                'llegar.',
    );
  }
}
