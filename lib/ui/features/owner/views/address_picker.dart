import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/theme/app_theme.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/maps/maps_providers.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';

/// Selector de dirección: búsqueda con sugerencias (debounce + caché) y mapa
/// donde el dueño marca o corrige el punto exacto.
///
/// La búsqueda es la alternativa accesible al mapa: elegir una sugerencia
/// también marca el punto.
class AddressPicker extends ConsumerStatefulWidget {
  const new({
    required this.street,
    required this.point,
    required this.onPointChanged,
    required this.mapController,
    this.communeName,
    this.enabled = true,
    this.onSuggestionPicked,
    this.mapHeight = 280,
    super.key,
  });

  /// Calle y número (lo que escribe el dueño y lo que se guarda).
  final TextEditingController street;
  final GeoPoint? point;
  final ValueChanged<GeoPoint> onPointChanged;
  final MapViewController mapController;

  /// Acota la búsqueda a la comuna elegida.
  final String? communeName;
  final bool enabled;
  final ValueChanged<GeocodingResult>? onSuggestionPicked;
  final double mapHeight;

  @override
  ConsumerState<AddressPicker> createState() => _AddressPickerState();
}

class _AddressPickerState extends ConsumerState<AddressPicker> {
  // El mapa se crea una vez; luego la cámara se mueve con el controlador.
  late final GeoPoint _initialCenter = widget.point ?? GeoPoint.initial;

  void _select(GeocodingResult r) {
    widget.street.text = r.label;
    ref.read(addressSearchProvider.notifier).clear();
    FocusScope.of(context).unfocus();
    _setPoint(r.point, reverse: false);
    widget.onSuggestionPicked?.call(r);
  }

  void _setPoint(GeoPoint p, {bool reverse = true}) {
    widget.onPointChanged(p);
    if (reverse) ref.read(reverseGeocodeProvider.notifier).pointChanged(p);
    unawaited(widget.mapController.animateTo(p, zoom: 17));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final search = ref.watch(addressSearchProvider);
    final nearby = ref.watch(reverseGeocodeProvider);
    final map = ref.watch(mapAdapterProvider);
    final point = widget.point;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const Key('address-street'),
          controller: widget.street,
          enabled: widget.enabled,
          maxLength: 200,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            labelText: 'Calle y número',
            hintText: 'Ej.: Av. Irarrázaval 1234',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => ref
              .read(addressSearchProvider.notifier)
              .queryChanged(v, communeName: widget.communeName),
          validator: (v) {
            final t = (v ?? '').trim();
            if (t.length < 3) return 'Escribe la calle y el número';
            return null;
          },
        ),
        switch (search) {
          AsyncLoading() => const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: LinearProgressIndicator(
              semanticsLabel: 'Buscando direcciones',
            ),
          ),
          AsyncError(:final error) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              friendlyError(error),
              key: const Key('address-search-error'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
          AsyncData(:final value) when value.isNotEmpty => Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Column(
              children: [
                for (final (i, r) in value.indexed)
                  ListTile(
                    key: Key('address-suggestion-$i'),
                    dense: true,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(r.label),
                    subtitle: r.communeName == null
                        ? null
                        : Text(r.communeName!),
                    onTap: widget.enabled ? () => _select(r) : null,
                  ),
              ],
            ),
          ),
          _ => const SizedBox.shrink(),
        },
        Semantics(
          label: 'Mapa. Toca para marcar la ubicación exacta.',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: SizedBox(
              key: const Key('address-map'),
              height: widget.mapHeight,
              child: map.buildMap(
                center: _initialCenter,
                zoom: point == null ? 12 : 17,
                controller: widget.mapController,
                markers: [
                  if (point != null)
                    MapMarker(
                      id: 'selected',
                      point: point,
                      label: 'Ubicación de la dirección',
                    ),
                ],
                onTap: widget.enabled ? _setPoint : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          point == null
              ? 'Toca el mapa para marcar la entrada de tu casa, o elige una '
                    'sugerencia.'
              : 'Punto marcado. Toca otro lugar del mapa para corregirlo.',
          key: const Key('address-point-hint'),
          style: theme.textTheme.bodySmall,
        ),
        if (nearby != null && nearby.label != widget.street.text) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cerca de: ${nearby.label}',
                  key: const Key('address-nearby'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton(
                key: const Key('address-use-nearby'),
                onPressed: widget.enabled
                    ? () => setState(() => widget.street.text = nearby.label)
                    : null,
                child: const Text('Usar'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
