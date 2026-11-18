import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/owner/views/address_picker.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

/// Punto de partida del vet: desde aquí se calcula la distancia (y el
/// recargo) de sus visitas agendadas. Solo lo ve él.
class VetBaseView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(vetBaseProvider)) {
        AsyncData(:final value) => _BaseForm(base: value),
        AsyncError(:final error) => Scaffold(
          appBar: AppBar(title: const Text('Punto de partida')),
          body: EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'No se pudo cargar.',
            message: friendlyError(error),
            isError: true,
          ),
        ),
        _ => Scaffold(
          appBar: AppBar(title: const Text('Punto de partida')),
          body: const LoadingView(),
        ),
      };
}

class _BaseForm extends ConsumerStatefulWidget {
  const new({this.base});

  final VetBase? base;

  @override
  ConsumerState<_BaseForm> createState() => _BaseFormState();
}

class _BaseFormState extends ConsumerState<_BaseForm> {
  final _map = MapViewController();
  final _street = TextEditingController();
  late GeoPoint? _point = widget.base?.point;
  late int? _communeId = widget.base?.communeId;
  int? _regionId;
  List<CommuneMatch>? _matches;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = _point;
    if (p != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pointChanged(p));
    }
  }

  @override
  void dispose() {
    _street.dispose();
    super.dispose();
  }

  /// La comuna se deriva del punto (como en las direcciones del dueño).
  Future<void> _pointChanged(GeoPoint p) async {
    setState(() {
      _point = p;
      _error = null;
    });
    final List<CommuneMatch> matches;
    try {
      matches = await ref.read(communesAtPointProvider(p).future);
    } on Object {
      return;
    }
    if (!mounted || _point != p) return;
    setState(() {
      _matches = matches;
      if (matches.isEmpty) {
        _error = 'La ubicación debe estar en Chile.';
      } else if (!matches.any((m) => m.communeId == _communeId)) {
        _regionId = matches.first.regionId;
        _communeId = matches.first.communeId;
      } else {
        _regionId = matches
            .firstWhere((m) => m.communeId == _communeId)
            .regionId;
      }
    });
  }

  Future<void> _save() async {
    if (_point == null || _communeId == null) {
      setState(() => _error = 'Marca tu punto de partida en el mapa.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(vetAgendaRepositoryProvider)
          .saveBase(VetBase(communeId: _communeId!, point: _point!));
      ref.invalidate(vetBaseProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Punto de partida guardado')),
      );
      context.pop();
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final communes = _regionId == null
        ? const <Commune>[]
        : ref.watch(communesProvider(_regionId!)).value ?? const <Commune>[];
    final matchIds = {
      for (final m in _matches ?? const <CommuneMatch>[]) m.communeId,
    };
    final selectable = communes.where((c) => matchIds.contains(c.id)).toList();
    String? communeName;
    for (final c in communes) {
      if (c.id == _communeId) communeName = c.name;
    }
    return FormPage(
      title: 'Punto de partida',
      children: [
        const InfoBanner(
          icon: Icons.lock_outline,
          message:
              'Solo tú ves este punto. Para proteger tu ubicación, la '
              'distancia y el recargo se calculan desde un punto aproximado '
              '(a 1–2 km de aquí), así que el precio puede variar un poco. '
              'Los dueños solo ven la distancia redondeada.',
        ),
        const SizedBox(height: 16),
        AddressPicker(
          street: _street,
          point: _point,
          mapController: _map,
          communeName: communeName,
          enabled: !_busy,
          onPointChanged: _pointChanged,
        ),
        const SizedBox(height: 16),
        KeyedSubtree(
          key: ValueKey('base-commune-$_communeId-${selectable.length}'),
          child: DropdownButtonFormField<int>(
            key: const Key('base-commune'),
            initialValue: selectable.any((c) => c.id == _communeId)
                ? _communeId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Comuna',
              helperText: 'Según el punto marcado en el mapa.',
              prefixIcon: Icon(Icons.location_city_outlined),
            ),
            items: [
              for (final c in selectable)
                DropdownMenuItem(value: c.id, child: Text(c.name)),
            ],
            onChanged: _busy ? null : (v) => setState(() => _communeId = v),
          ),
        ),
        if (_error != null) ...[const SizedBox(height: 16), FormError(_error!)],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('base-save'),
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Guardando',
                  ),
                )
              : const Text('Guardar punto de partida'),
        ),
      ],
    );
  }
}
