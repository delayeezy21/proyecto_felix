import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/ui/core/app_dropdown.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/owner/views/address_picker.dart';

/// Crear o editar una dirección. Sin [addressId] crea una nueva.
class AddressFormView extends ConsumerWidget {
  const new({this.addressId, super.key});

  final String? addressId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (addressId == null) return const _AddressForm();
    return switch (ref.watch(myAddressesProvider)) {
      AsyncData(:final value) => switch (value.where(
        (a) => a.id == addressId,
      )) {
        final found when found.isNotEmpty => _AddressForm(address: found.first),
        _ => Scaffold(
          appBar: AppBar(title: const Text('Dirección')),
          body: const EmptyState(
            icon: Icons.search_off,
            title: 'No encontramos esta dirección.',
          ),
        ),
      },
      AsyncError(:final error) => Scaffold(
        appBar: AppBar(title: const Text('Dirección')),
        body: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'No se pudo cargar.',
          message: friendlyError(error),
          isError: true,
        ),
      ),
      _ => Scaffold(
        appBar: AppBar(title: const Text('Dirección')),
        body: const LoadingView(),
      ),
    };
  }
}

class _AddressForm extends ConsumerStatefulWidget {
  const new({this.address});

  final Address? address;

  @override
  ConsumerState<_AddressForm> createState() => _AddressFormState();
}

class _AddressFormState extends ConsumerState<_AddressForm> {
  final _form = GlobalKey<FormState>();
  final _map = MapViewController();
  late final _label = TextEditingController(
    text: widget.address?.label ?? 'Casa',
  );
  late final _street = TextEditingController(text: widget.address?.streetText);
  late final _details = TextEditingController(text: widget.address?.details);
  late int? _regionId = widget.address?.regionId;
  late int? _communeId = widget.address?.communeId;
  late GeoPoint? _point = widget.address?.point;

  /// Comunas compatibles con el punto (null = aún no se consultan).
  List<CommuneMatch>? _matches;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.address != null;

  @override
  void dispose() {
    _label.dispose();
    _street.dispose();
    _details.dispose();
    super.dispose();
  }

  Commune? _commune(List<Commune> communes) {
    for (final c in communes) {
      if (c.id == _communeId) return c;
    }
    return null;
  }

  Future<void> _communeChanged(int? id, List<Commune> communes) async {
    setState(() => _communeId = id);
    // Sin punto marcado, acerca el mapa al centro de la comuna (dato del
    // servidor: no se consulta al geocoder).
    final center = _commune(communes)?.center;
    if (center != null && _point == null) {
      await _map.animateTo(center, zoom: 14);
    }
  }

  /// QA-F4-02: al marcar el punto, la comuna se deriva de él. Si la elegida
  /// no es compatible, se propone la más probable; fuera de Chile, se avisa.
  Future<void> _pointChanged(GeoPoint p) async {
    setState(() {
      _point = p;
      _matches = null;
    });
    final List<CommuneMatch> matches;
    try {
      matches = await ref.read(communesAtPointProvider(p).future);
    } on Object {
      return; // Sin sugerencia: el servidor igual valida al guardar.
    }
    if (!mounted || _point != p) return;
    setState(() {
      _matches = matches;
      if (matches.isEmpty) {
        _error = 'La ubicación debe estar en Chile.';
        return;
      }
      if (_error == 'La ubicación debe estar en Chile.') _error = null;
      if (!matches.any((m) => m.communeId == _communeId)) {
        _regionId = matches.first.regionId;
        _communeId = matches.first.communeId;
      }
    });
  }

  void _regionChanged(int? id) => setState(() {
    _regionId = id;
    final inRegion = (_matches ?? const <CommuneMatch>[]).where(
      (m) => m.regionId == id,
    );
    _communeId = inRegion.isEmpty ? null : inRegion.first.communeId;
  });

  Future<void> _save() async {
    setState(() => _error = null);
    final valid = _form.currentState?.validate() ?? false;
    if (_point == null) {
      setState(
        () => _error =
            'Marca la ubicación en el mapa o elige una sugerencia de la lista.',
      );
      return;
    }
    if (!valid) return;
    if (!_point!.isInChile || (_matches?.isEmpty ?? false)) {
      setState(() => _error = 'La ubicación debe estar en Chile.');
      return;
    }
    final draft = AddressDraft(
      label: _label.text,
      streetText: _street.text,
      details: _details.text,
      communeId: _communeId!,
      point: _point!,
    );
    setState(() => _busy = true);
    final repo = ref.read(addressRepositoryProvider);
    try {
      if (_editing) {
        await repo.update(widget.address!.id, draft);
      } else {
        await repo.create(draft);
      }
      ref.invalidate(myAddressesProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_editing ? 'Dirección guardada' : 'Dirección agregada'),
        ),
      );
      context.pop();
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleActive() async {
    final a = widget.address!;
    final done = await runWithFeedback(
      context,
      () => ref
          .read(addressRepositoryProvider)
          .setActive(a.id, active: !a.active),
      onDone: () => ref.invalidate(myAddressesProvider),
      success: a.active ? 'Dirección desactivada' : 'Dirección reactivada',
    );
    if (done && mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final regions = ref.watch(regionsProvider).value ?? const <Region>[];
    final communes = _regionId == null
        ? const <Commune>[]
        : ref.watch(communesProvider(_regionId!)).value ?? const <Commune>[];
    // Con un punto marcado, solo se ofrecen las comunas compatibles con él
    // (si la región elegida tiene alguna).
    final matchIds = _matches == null || _matches!.isEmpty
        ? null
        : {for (final m in _matches!) m.communeId};
    final selectable =
        matchIds == null || !communes.any((c) => matchIds.contains(c.id))
        ? communes
        : communes.where((c) => matchIds.contains(c.id)).toList();
    final address = widget.address;

    return FormPage(
      title: _editing ? 'Editar dirección' : 'Nueva dirección',
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const InfoBanner(
                icon: Icons.lock_outline,
                message:
                    'Tu dirección exacta solo la ves tú. Un veterinario con '
                    'una solicitud ve solo la comuna y la distancia '
                    'aproximada; la dirección exacta la ve solo el que '
                    'acepta tu visita, mientras está activa.',
              ),
              if (address != null && !address.active) ...[
                const SizedBox(height: 12),
                const InfoBanner(
                  tone: BannerTone.warning,
                  message: 'Esta dirección está desactivada.',
                ),
              ],
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('address-label'),
                controller: _label,
                enabled: !_busy,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: 'Nombre de la dirección',
                  hintText: 'Casa, Trabajo, Casa de mi mamá…',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Ponle un nombre' : null,
              ),
              const SizedBox(height: 8),
              // KeyedSubtree: si el punto propone otra región, el campo se
              // reconstruye con el valor nuevo.
              KeyedSubtree(
                key: ValueKey('region-$_regionId'),
                child: AppDropdown<int>(
                  key: const Key('address-region'),
                  initialValue: _regionId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Región',
                    prefixIcon: Icon(Icons.map_outlined),
                  ),
                  items: [
                    for (final r in regions)
                      DropdownMenuItem(value: r.id, child: Text(r.name)),
                  ],
                  onChanged: _busy ? null : _regionChanged,
                  validator: (v) => v == null ? 'Elige la región' : null,
                ),
              ),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: ValueKey('commune-$_communeId'),
                child: AppDropdown<int>(
                  key: Key('address-commune-$_regionId'),
                  initialValue: selectable.any((c) => c.id == _communeId)
                      ? _communeId
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Comuna',
                    prefixIcon: const Icon(Icons.location_city_outlined),
                    helperText: matchIds == null
                        ? null
                        : 'Según el punto marcado en el mapa.',
                  ),
                  items: [
                    for (final c in selectable)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: _busy || _regionId == null
                      ? null
                      : (v) => _communeChanged(v, communes),
                  validator: (v) {
                    if (v == null) return 'Elige la comuna';
                    if (matchIds != null && !matchIds.contains(v)) {
                      return 'El punto marcado no está en esta comuna';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(height: 16),
              AddressPicker(
                street: _street,
                point: _point,
                mapController: _map,
                communeName: _commune(communes)?.name,
                enabled: !_busy,
                onPointChanged: _pointChanged,
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('address-details'),
                controller: _details,
                enabled: !_busy,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Depto., casa o referencia (opcional)',
                  prefixIcon: Icon(Icons.apartment_outlined),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                FormError(_error!),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('address-save'),
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: 'Guardando',
                        ),
                      )
                    : Text(_editing ? 'Guardar cambios' : 'Guardar dirección'),
              ),
              if (address != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('address-toggle-active'),
                  onPressed: _busy ? null : _toggleActive,
                  icon: Icon(
                    address.active
                        ? Icons.location_off_outlined
                        : Icons.location_on_outlined,
                  ),
                  label: Text(address.active ? 'Desactivar' : 'Reactivar'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
