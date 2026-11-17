import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';

/// Crear o editar una mascota. Sin [petId] crea una nueva.
class PetFormView extends ConsumerWidget {
  const new({this.petId, super.key});

  final String? petId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (petId == null) return const _PetForm();
    return switch (ref.watch(myPetsProvider)) {
      AsyncData(:final value) => switch (value.where((p) => p.id == petId)) {
        final found when found.isNotEmpty => _PetForm(pet: found.first),
        _ => const _NotFound(),
      },
      AsyncError(:final error) => Scaffold(
        appBar: AppBar(title: const Text('Mascota')),
        body: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'No se pudo cargar.',
          message: friendlyError(error),
          isError: true,
        ),
      ),
      _ => Scaffold(
        appBar: AppBar(title: const Text('Mascota')),
        body: const LoadingView(),
      ),
    };
  }
}

class _NotFound extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Mascota')),
    body: const EmptyState(
      icon: Icons.search_off,
      title: 'No encontramos esta mascota.',
    ),
  );
}

class _PetForm extends ConsumerStatefulWidget {
  const new({this.pet});

  final Pet? pet;

  @override
  ConsumerState<_PetForm> createState() => _PetFormState();
}

class _PetFormState extends ConsumerState<_PetForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.pet?.name);
  late final _chip = TextEditingController(text: widget.pet?.microchip);
  late int? _speciesId = widget.pet?.speciesId;
  late int? _breedId = widget.pet?.breedId;
  late PetSex _sex = widget.pet?.sex ?? PetSex.unknown;
  late bool _sterilized = widget.pet?.sterilized ?? false;
  late int? _birthYear = widget.pet?.birthDateApprox?.year;
  // El mes es opcional: null = "No sé el mes".
  late int? _birthMonth = widget.pet?.birthDateApprox == null
      ? null
      : widget.pet!.birthDateApprox!.month;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.pet != null;

  @override
  void dispose() {
    _name.dispose();
    _chip.dispose();
    super.dispose();
  }

  DateTime? get _birth =>
      _birthYear == null ? null : DateTime(_birthYear!, _birthMonth ?? 1);

  Future<void> _save() async {
    setState(() => _error = null);
    if (!(_form.currentState?.validate() ?? false)) return;
    final draft = PetDraft(
      name: _name.text,
      speciesId: _speciesId!,
      breedId: _breedId,
      sex: _sex,
      birthDateApprox: _birth,
      sterilized: _sterilized,
      microchip: _chip.text.replaceAll(' ', ''),
    );
    setState(() => _busy = true);
    final repo = ref.read(petRepositoryProvider);
    try {
      if (_editing) {
        await repo.update(widget.pet!.id, draft);
      } else {
        await repo.create(draft);
      }
      ref.invalidate(myPetsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_editing ? 'Cambios guardados' : 'Mascota agregada'),
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
    final pet = widget.pet!;
    if (pet.active) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('¿Desactivar a ${pet.name}?'),
          content: const Text(
            'No podrás pedir visitas para esta mascota. Su ficha clínica se '
            'conserva y puedes reactivarla cuando quieras.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              key: const Key('pet-deactivate-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Desactivar'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final done = await runWithFeedback(
      context,
      () => ref
          .read(petRepositoryProvider)
          .setActive(pet.id, active: !pet.active),
      onDone: () => ref.invalidate(myPetsProvider),
      success: pet.active ? 'Mascota desactivada' : 'Mascota reactivada',
    );
    if (done && mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final species =
        ref.watch(catalogItemsProvider(CatalogKind.species)).value ??
        const <CatalogItem>[];
    final breeds = _speciesId == null
        ? const <Breed>[]
        : ref.watch(breedsProvider(_speciesId!)).value ?? const <Breed>[];
    final pet = widget.pet;
    final now = DateTime.now();

    // Si la especie o la raza de una mascota existente se desactivó en el
    // catálogo, se muestra igual (sin poder elegirla de nuevo).
    final speciesItems = [
      for (final s in species)
        DropdownMenuItem(value: s.id, child: Text(s.name)),
      if (_speciesId != null && !species.any((s) => s.id == _speciesId))
        DropdownMenuItem(
          value: _speciesId,
          enabled: false,
          child: Text(pet?.speciesName ?? 'Especie no disponible'),
        ),
    ];
    final breedItems = <DropdownMenuItem<int?>>[
      const DropdownMenuItem(child: Text('Sin raza / no sé')),
      for (final b in breeds)
        DropdownMenuItem(value: b.id, child: Text(b.name)),
      if (_breedId != null && !breeds.any((b) => b.id == _breedId))
        DropdownMenuItem(
          value: _breedId,
          enabled: false,
          child: Text(pet?.breedName ?? 'Raza no disponible'),
        ),
    ];

    return FormPage(
      title: _editing ? 'Editar mascota' : 'Nueva mascota',
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pet != null && !pet.active) ...[
                const InfoBanner(
                  tone: BannerTone.warning,
                  message:
                      'Esta mascota está desactivada. Reactívala para pedir '
                      'visitas.',
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                key: const Key('pet-name'),
                controller: _name,
                enabled: !_busy,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Escribe el nombre' : null,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                key: const Key('pet-species'),
                initialValue: _speciesId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Especie',
                  prefixIcon: Icon(Icons.pets),
                ),
                items: speciesItems,
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        if (v != _speciesId) _breedId = null;
                        _speciesId = v;
                      }),
                validator: (v) => v == null ? 'Elige la especie' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int?>(
                // La key cambia con la especie para reiniciar la raza.
                key: Key('pet-breed-$_speciesId'),
                initialValue: _breedId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Raza (opcional)',
                  prefixIcon: const Icon(Icons.category_outlined),
                  helperText: _speciesId != null && breeds.isEmpty
                      ? 'No hay razas en el catálogo para esta especie.'
                      : null,
                ),
                items: breedItems,
                onChanged: _busy || _speciesId == null
                    ? null
                    : (v) => setState(() => _breedId = v),
              ),
              const SizedBox(height: 16),
              Text('Sexo', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<PetSex>(
                key: const Key('pet-sex'),
                segments: [
                  for (final s in PetSex.values)
                    ButtonSegment(value: s, label: Text(s.label)),
                ],
                selected: {_sex},
                showSelectedIcon: false,
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() => _sex = s.first),
              ),
              const SizedBox(height: 16),
              Text(
                'Fecha de nacimiento aproximada',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      key: const Key('pet-birth-year'),
                      initialValue: _birthYear,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Año'),
                      items: [
                        const DropdownMenuItem(child: Text('No sé')),
                        for (var y = now.year; y >= now.year - 40; y--)
                          DropdownMenuItem(value: y, child: Text('$y')),
                        if (_birthYear != null && _birthYear! < now.year - 40)
                          DropdownMenuItem(
                            value: _birthYear,
                            child: Text('$_birthYear'),
                          ),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() {
                              _birthYear = v;
                              if (v == null) _birthMonth = null;
                            }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<int?>(
                      key: Key('pet-birth-month-$_birthYear'),
                      initialValue: _birthMonth,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Mes'),
                      items: [
                        const DropdownMenuItem(child: Text('No sé')),
                        for (var m = 1; m <= 12; m++)
                          DropdownMenuItem(
                            value: m,
                            child: Text(_months[m - 1]),
                          ),
                      ],
                      onChanged: _busy || _birthYear == null
                          ? null
                          : (v) => setState(() => _birthMonth = v),
                      validator: (m) =>
                          _birthYear == now.year && (m ?? 1) > now.month
                          ? 'No puede ser futura'
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('pet-sterilized'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Esterilizada o castrada'),
                value: _sterilized,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _sterilized = v),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('pet-microchip'),
                controller: _chip,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                maxLength: 15,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Microchip (opcional)',
                  helperText:
                      '15 dígitos. Solo lo ves tú y el veterinario que '
                      'atiende.',
                  prefixIcon: Icon(Icons.memory_outlined),
                ),
                validator: validateMicrochip,
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                FormError(_error!),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('pet-save'),
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: 'Guardando',
                        ),
                      )
                    : Text(_editing ? 'Guardar cambios' : 'Agregar mascota'),
              ),
              if (pet != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('pet-toggle-active'),
                  onPressed: _busy ? null : _toggleActive,
                  icon: Icon(
                    pet.active
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  label: Text(pet.active ? 'Desactivar' : 'Reactivar'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

const _months = [
  'Enero',
  'Febrero',
  'Marzo',
  'Abril',
  'Mayo',
  'Junio',
  'Julio',
  'Agosto',
  'Septiembre',
  'Octubre',
  'Noviembre',
  'Diciembre',
];
