import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/admin/view_models/admin_catalog_providers.dart';
import 'package:proyecto_felix/ui/features/admin/views/admin_foundations_tab.dart';
import 'package:proyecto_felix/ui/features/admin/views/admin_vet_review_view.dart';
import 'package:proyecto_felix/ui/features/admin/views/admin_visits_tab.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

/// Panel del administrador: catálogos, tarifas, parámetros, clínicas 24 h y
/// fundaciones, y un resumen agregado de visitas (sin datos personales).
class AdminHomeView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Administración'),
          actions: [
            IconButton(
              key: const Key('sign-out'),
              tooltip: 'Cerrar sesión',
              icon: const Icon(Icons.logout),
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).signOut(),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(
                icon: Icon(Icons.verified_user_outlined),
                text: 'Veterinarios',
              ),
              Tab(icon: Icon(Icons.pets), text: 'Especies'),
              Tab(
                icon: Icon(Icons.medical_services_outlined),
                text: 'Especialidades',
              ),
              Tab(icon: Icon(Icons.sell_outlined), text: 'Tarifas'),
              Tab(icon: Icon(Icons.tune), text: 'Parámetros'),
              Tab(
                icon: Icon(Icons.local_hospital_outlined),
                text: 'Clínicas 24 h',
              ),
              Tab(
                icon: Icon(Icons.volunteer_activism_outlined),
                text: 'Fundaciones',
              ),
              Tab(icon: Icon(Icons.event_note_outlined), text: 'Visitas'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            AdminVetApplicationsTab(),
            _CatalogTab(kind: CatalogKind.species),
            _CatalogTab(kind: CatalogKind.specialties),
            _TariffsTab(),
            _PricingTab(),
            _ClinicsTab(),
            AdminFoundationsTab(),
            AdminVisitsTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

/// Ejecuta una acción del admin, muestra el error si falla y refresca.
Future<bool> _runAction(
  BuildContext context,
  Future<void> Function() action, {
  required VoidCallback onDone,
  String? success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    onDone();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(catalogErrorMessage(e))));
    return false;
  }
}

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? Function(String?)? validator,
  TextInputType? keyboard,
}) {
  final controller = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: TextFormField(
          key: const Key('dialog-field'),
          controller: controller,
          autofocus: true,
          keyboardType: keyboard,
          decoration: InputDecoration(labelText: label),
          validator: validator,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('dialog-save'),
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              Navigator.of(context).pop(controller.text.trim());
            }
          },
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
}

Widget _asyncList<T>(
  AsyncValue<List<T>> value,
  Widget Function(List<T> items) builder,
  VoidCallback retry,
) => switch (value) {
  AsyncData(:final value) => builder(value),
  AsyncError(:final error) => _ErrorState(
    message: catalogErrorMessage(error),
    retry: retry,
  ),
  _ => const LoadingView(),
};

/// Error de carga con botón para reintentar.
class _ErrorState extends StatelessWidget {
  const new({required this.message, this.retry});

  final String message;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: EmptyState(
      icon: Icons.cloud_off,
      isError: true,
      title: message,
      action: retry == null
          ? null
          : OutlinedButton.icon(
              onPressed: retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
    ),
  );
}

/// Lista separada por divisores, con ancho máximo y espacio para el botón
/// flotante al final.
Widget _list({
  required int itemCount,
  required IndexedWidgetBuilder itemBuilder,
  bool hasFab = false,
}) => MaxWidth(
  child: ListView.separated(
    padding: EdgeInsets.fromLTRB(8, 8, 8, hasFab ? 96 : 16),
    itemCount: itemCount,
    separatorBuilder: (_, _) => const Divider(indent: 16, endIndent: 16),
    itemBuilder: itemBuilder,
  ),
);

// ---------------------------------------------------------------------------
// Especies y especialidades
// ---------------------------------------------------------------------------

class _CatalogTab extends ConsumerWidget {
  const new({required this.kind});

  final CatalogKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(catalogRepositoryProvider);
    void refresh() => ref.invalidate(adminItemsProvider(kind));

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: Key('add-${kind.name}'),
        icon: const Icon(Icons.add),
        label: Text('Agregar ${kind.singular}'),
        onPressed: () async {
          final name = await _askText(
            context,
            title: 'Nueva ${kind.singular}',
            label: 'Nombre',
            validator: Validators.displayName,
          );
          if (name == null || !context.mounted) return;
          await _runAction(
            context,
            () => repo.createItem(kind, name),
            onDone: refresh,
            success: '"$name" agregada',
          );
        },
      ),
      body: _asyncList(
        ref.watch(adminItemsProvider(kind)),
        (items) => items.isEmpty
            ? SingleChildScrollView(
                child: EmptyState(
                  icon: kind == CatalogKind.species
                      ? Icons.pets
                      : Icons.medical_services_outlined,
                  title: 'Aún no hay ${kind.title.toLowerCase()}.',
                  message: 'Usa el botón "Agregar ${kind.singular}".',
                ),
              )
            : _list(
                hasFab: true,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  return ListTile(
                    key: Key('item-${item.slug}'),
                    leading: Icon(
                      kind == CatalogKind.species
                          ? Icons.pets
                          : Icons.medical_services_outlined,
                      color: item.active
                          ? null
                          : Theme.of(context).disabledColor,
                    ),
                    title: Text(item.name),
                    subtitle: item.active ? null : const Text('Inactiva'),
                    onTap: () async {
                      final name = await _askText(
                        context,
                        title: 'Renombrar',
                        label: 'Nombre',
                        initial: item.name,
                        validator: Validators.displayName,
                      );
                      if (name == null ||
                          name == item.name ||
                          !context.mounted) {
                        return;
                      }
                      await _runAction(
                        context,
                        () => repo.renameItem(kind, item.id, name),
                        onDone: refresh,
                      );
                    },
                    trailing: Switch(
                      key: Key('active-${item.slug}'),
                      value: item.active,
                      onChanged: (v) => _runAction(
                        context,
                        () => repo.setItemActive(kind, item.id, active: v),
                        onDone: refresh,
                      ),
                    ),
                  );
                },
              ),
        refresh,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tarifas
// ---------------------------------------------------------------------------

String? _validatePrice(String? v) {
  final n = int.tryParse((v ?? '').replaceAll('.', ''));
  if (n == null || n <= 0) return 'Ingresa un monto mayor a 0';
  if (n > 10000000) return 'Monto demasiado alto';
  return null;
}

class _TariffsTab extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(catalogRepositoryProvider);
    void refresh() => ref.invalidate(adminTariffsProvider);

    return _asyncList(
      ref.watch(adminTariffsProvider),
      (tariffs) => tariffs.isEmpty
          ? const SingleChildScrollView(
              child: EmptyState(
                icon: Icons.sell_outlined,
                title: 'Aún no hay tarifas.',
              ),
            )
          : _list(
              itemCount: tariffs.length,
              itemBuilder: (context, i) {
                final t = tariffs[i];
                final theme = Theme.of(context);
                return ListTile(
                  key: Key('tariff-${t.id}'),
                  leading: const Icon(Icons.sell_outlined),
                  title: Text(t.specialtyName),
                  subtitle: Text(t.speciesName ?? 'Todas las especies'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        formatClp(t.basePrice),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                  onTap: () async {
                    final value = await _askText(
                      context,
                      title: 'Tarifa base · ${t.specialtyName}',
                      label: 'Monto en pesos',
                      initial: t.basePrice.toString(),
                      keyboard: TextInputType.number,
                      validator: _validatePrice,
                    );
                    if (value == null || !context.mounted) return;
                    await _runAction(
                      context,
                      () => repo.updateTariffPrice(
                        t.id,
                        int.parse(value.replaceAll('.', '')),
                      ),
                      onDone: refresh,
                      success: 'Tarifa actualizada',
                    );
                  },
                );
              },
            ),
      refresh,
    );
  }
}

// ---------------------------------------------------------------------------
// Parámetros económicos (versionados)
// ---------------------------------------------------------------------------

class _PricingTab extends ConsumerStatefulWidget {
  const new();

  @override
  ConsumerState<_PricingTab> createState() => _PricingTabState();
}

class _PricingTabState extends ConsumerState<_PricingTab> {
  final _formKey = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  PricingConfig? _loaded;

  TextEditingController _c(String key) =>
      _fields.putIfAbsent(key, TextEditingController.new);

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(PricingConfig p) {
    if (identical(_loaded, p)) return;
    _loaded = p;
    String n(num v) => v % 1 == 0 ? v.toInt().toString() : v.toString();
    _c('commission').text = n(p.commissionPct);
    _c('foundation').text = n(p.foundationPct);
    _c('urgent').text = n(p.urgentPct);
    _c('perKm').text = p.perKm.toString();
    _c('freeKm').text = p.freeKm.toString();
    _c('cancelFee').text = p.cancelFee.toString();
  }

  static String? _pct(String? v, {double max = 100}) {
    final n = double.tryParse((v ?? '').replaceAll(',', '.'));
    if (n == null || n < 0 || n > max) return 'Entre 0 y ${max.toInt()}';
    return null;
  }

  static String? _int(String? v) {
    final n = int.tryParse(v ?? '');
    if (n == null || n < 0) return 'Número entero ≥ 0';
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    double d(String k) => double.parse(_c(k).text.replaceAll(',', '.'));
    final config = PricingConfig(
      commissionPct: d('commission'),
      foundationPct: d('foundation'),
      urgentPct: d('urgent'),
      perKm: int.parse(_c('perKm').text),
      freeKm: int.parse(_c('freeKm').text),
      cancelFee: int.parse(_c('cancelFee').text),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Guardar nueva versión?'),
        content: const Text(
          'Los nuevos valores aplican a las visitas que se coticen desde '
          'ahora. Las visitas ya cotizadas mantienen su precio.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('pricing-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runAction(
      context,
      () => ref.read(catalogRepositoryProvider).createPricingVersion(config),
      onDone: () => ref.invalidate(adminPricingProvider),
      success: 'Nueva versión de parámetros vigente',
    );
  }

  Widget _field(
    String key,
    String label,
    String? Function(String?) validator, {
    String? suffix,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      key: Key('pricing-$key'),
      controller: _c(key),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9.,]'))],
      decoration: InputDecoration(labelText: label, suffixText: suffix),
      validator: validator,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pricing = ref.watch(adminPricingProvider);
    return switch (pricing) {
      AsyncData(:final value) => Builder(
        builder: (context) {
          _fill(value);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const InfoBanner(
                        icon: Icons.history,
                        message:
                            'Valores vigentes. Al guardar se crea una nueva '
                            'versión; la anterior queda en el historial.',
                      ),
                      const SizedBox(height: 24),
                      _heading(context, 'Comisión'),
                      _field(
                        'commission',
                        'Comisión de la app',
                        _pct,
                        suffix: '%',
                      ),
                      _field(
                        'foundation',
                        'Parte de la comisión a fundación',
                        _pct,
                        suffix: '%',
                      ),
                      const SizedBox(height: 8),
                      _heading(context, 'Recargos y cargos'),
                      _field(
                        'urgent',
                        'Recargo por urgencia',
                        (v) => _pct(v, max: 300),
                        suffix: '%',
                      ),
                      _field('perKm', 'Recargo por km', _int, suffix: r'$'),
                      _field('freeKm', 'Km sin recargo', _int, suffix: 'km'),
                      _field(
                        'cancelFee',
                        'Cargo por cancelación tardía',
                        _int,
                        suffix: r'$',
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        key: const Key('pricing-save'),
                        onPressed: _save,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Guardar nueva versión'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
      AsyncError(:final error) => _ErrorState(
        message: catalogErrorMessage(error),
        retry: () => ref.invalidate(adminPricingProvider),
      ),
      _ => const LoadingView(),
    };
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

// ---------------------------------------------------------------------------
// Clínicas 24 h
// ---------------------------------------------------------------------------

class _ClinicsTab extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(catalogRepositoryProvider);
    void refresh() => ref.invalidate(adminClinicsProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-clinic'),
        icon: const Icon(Icons.add),
        label: const Text('Agregar clínica'),
        onPressed: () async {
          final created = await showDialog<bool>(
            context: context,
            builder: (_) => const _ClinicDialog(),
          );
          if (created ?? false) refresh();
        },
      ),
      body: _asyncList(
        ref.watch(adminClinicsProvider),
        (clinics) => clinics.isEmpty
            ? const SingleChildScrollView(
                child: EmptyState(
                  icon: Icons.local_hospital_outlined,
                  title: 'Aún no hay clínicas registradas.',
                  message:
                      'Se ofrecen a los dueños cuando no hay veterinarios '
                      'disponibles para una urgencia.',
                ),
              )
            : _list(
                hasFab: true,
                itemCount: clinics.length,
                itemBuilder: (context, i) {
                  final c = clinics[i];
                  return ListTile(
                    key: Key('clinic-${c.id}'),
                    leading: const Icon(Icons.local_hospital_outlined),
                    title: Text(c.name),
                    subtitle: Text(
                      '${c.communeName} · ${c.address}\n${c.phone}',
                    ),
                    isThreeLine: true,
                    trailing: Switch(
                      value: c.active,
                      onChanged: (v) => _runAction(
                        context,
                        () => repo.setClinicActive(c.id, active: v),
                        onDone: refresh,
                      ),
                    ),
                  );
                },
              ),
        refresh,
      ),
    );
  }
}

class _ClinicDialog extends ConsumerStatefulWidget {
  const new();

  @override
  ConsumerState<_ClinicDialog> createState() => _ClinicDialogState();
}

class _ClinicDialogState extends ConsumerState<_ClinicDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  int? _regionId;
  int? _communeId;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final ok = await _runAction(
      context,
      () => ref
          .read(catalogRepositoryProvider)
          .createClinic(
            name: _name.text,
            communeId: _communeId!,
            address: _address.text,
            phone: _phone.text,
          ),
      onDone: () {},
      success: 'Clínica agregada',
    );
    if (!mounted) return;
    if (ok) {
      navigator.pop(true);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final regions = ref.watch(regionsProvider).value ?? const <Region>[];
    final communes = _regionId == null
        ? const <Commune>[]
        : ref.watch(communesProvider(_regionId!)).value ?? const <Commune>[];

    return AlertDialog(
      title: const Text('Nueva clínica 24 h'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                TextFormField(
                  key: const Key('clinic-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Nombre'),
                  validator: Validators.displayName,
                ),
                DropdownButtonFormField<int>(
                  key: const Key('clinic-region'),
                  initialValue: _regionId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Región'),
                  items: [
                    for (final r in regions)
                      DropdownMenuItem(value: r.id, child: Text(r.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _regionId = v;
                    _communeId = null;
                  }),
                  validator: (v) => v == null ? 'Elige la región' : null,
                ),
                DropdownButtonFormField<int>(
                  key: Key('clinic-commune-$_regionId'),
                  initialValue: _communeId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Comuna'),
                  items: [
                    for (final c in communes)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: _regionId == null
                      ? null
                      : (v) => setState(() => _communeId = v),
                  validator: (v) => v == null ? 'Elige la comuna' : null,
                ),
                TextFormField(
                  key: const Key('clinic-address'),
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Dirección'),
                  validator: (v) => (v?.trim().length ?? 0) < 3
                      ? 'Ingresa la dirección'
                      : null,
                ),
                TextFormField(
                  key: const Key('clinic-phone'),
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Teléfono'),
                  validator: (v) => Validators.phone(v, required: true),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('clinic-save'),
          onPressed: _saving ? null : _save,
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
