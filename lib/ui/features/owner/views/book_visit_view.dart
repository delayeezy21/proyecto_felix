import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/owner/views/quote_breakdown.dart';
import 'package:proyecto_felix/ui/features/ratings/views/vet_ratings_card.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

/// Agendar: mascota y dirección → vets disponibles con horarios → precio
/// (cotización del servidor con ese vet) → reservar.
class BookVisitView extends ConsumerStatefulWidget {
  const new({
    this.initialPetId,
    this.initialAddressId,
    this.fromUrgent = false,
    super.key,
  });

  /// Preselección al venir de una urgencia sin vet ("Agendar primera hora
  /// libre"): misma mascota y dirección, buscando desde hoy.
  final String? initialPetId;
  final String? initialAddressId;
  final bool fromUrgent;

  @override
  ConsumerState<BookVisitView> createState() => _BookVisitViewState();
}

class _BookVisitViewState extends ConsumerState<BookVisitView> {
  final _form = GlobalKey<FormState>();
  final _donation = TextEditingController();
  final _notes = TextEditingController();
  late String? _petId = widget.initialPetId;
  late String? _addressId = widget.initialAddressId;
  int? _specialtyId;
  late DateTime _date = widget.fromUrgent
      ? _today()
      : _today().add(const Duration(days: 1));

  List<AvailableVet>? _vets;
  bool _searching = false;
  String? _vetId;
  DateTime? _slot;
  Quote? _quote;
  bool _quoting = false;
  bool _booking = false;
  String? _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void dispose() {
    _donation.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// Cambiar la búsqueda invalida los horarios y el precio mostrados.
  void _reset(VoidCallback fn) => setState(() {
    fn();
    _vets = null;
    _vetId = null;
    _slot = null;
    _quote = null;
    _error = null;
  });

  Future<void> _pickDate() async {
    final today = _today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today,
      lastDate: today.add(const Duration(days: 30)),
      helpText: 'Día de la visita',
    );
    if (picked != null) _reset(() => _date = picked);
  }

  Future<void> _search() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    _reset(() => _searching = true);
    try {
      final vets = await ref
          .read(visitRepositoryProvider)
          .availableVets(
            petId: _petId!,
            addressId: _addressId!,
            specialtyId: _specialtyId!,
            date: _date,
          );
      if (mounted) setState(() => _vets = vets);
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _choose(String vetId, DateTime slot) async {
    if (validateDonation(_donation.text) != null) return;
    setState(() {
      _vetId = vetId;
      _slot = slot;
      _quote = null;
      _quoting = true;
      _error = null;
    });
    try {
      final q = await ref
          .read(quoteRepositoryProvider)
          .quote(
            QuoteRequest(
              petId: _petId!,
              addressId: _addressId!,
              specialtyId: _specialtyId!,
              mode: VisitMode.scheduled,
              vetId: vetId,
              extraDonation: parseDonation(_donation.text),
            ),
          );
      if (mounted && _vetId == vetId && _slot == slot) {
        setState(() => _quote = q);
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _quoting = false);
    }
  }

  Future<void> _book() async {
    final q = _quote;
    if (q == null || _vetId == null || _slot == null) return;
    setState(() {
      _booking = true;
      _error = null;
    });
    try {
      final visit = await ref
          .read(visitRepositoryProvider)
          .book(
            quoteId: q.id,
            vetId: _vetId!,
            petId: _petId!,
            addressId: _addressId!,
            scheduledAt: _slot!,
            notes: _notes.text,
          );
      ref.invalidate(myVisitsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Solicitud enviada. El veterinario debe confirmarla.'),
        ),
      );
      context.pushReplacement(AppRoutes.ownerVisit(visit.id));
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _booking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pets = (ref.watch(myPetsProvider).value ?? const []).where(
      (p) => p.active,
    );
    final addresses = (ref.watch(myAddressesProvider).value ?? const []).where(
      (a) => a.active,
    );
    final specialties =
        (ref.watch(catalogItemsProvider(CatalogKind.specialties)).value ??
                const <CatalogItem>[])
            .where((s) => s.active);
    final busy = _searching || _quoting || _booking;
    final petReady = pets.any((p) => p.id == _petId);
    final addressReady = addresses.any((a) => a.id == _addressId);

    return FormPage(
      title: 'Agendar visita',
      children: [
        if (widget.fromUrgent) ...[
          const InfoBanner(
            key: Key('book-from-urgent'),
            icon: Icons.event_available_outlined,
            message:
                'Elige la especialidad y busca: te mostramos los horarios '
                'libres desde hoy. Si no hay, prueba el día siguiente.',
          ),
          const SizedBox(height: 12),
        ],
        const InfoBanner(
          icon: Icons.lock_outline,
          message:
              'El veterinario verá tu dirección exacta solo cuando confirme '
              'la visita y mientras esté activa.',
        ),
        const SizedBox(height: 16),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              // Se reconstruyen cuando llega la mascota o la dirección
              // preseleccionada.
              KeyedSubtree(
                key: ValueKey('pet-$petReady'),
                child: DropdownButtonFormField<String>(
                  key: const Key('book-pet'),
                  initialValue: petReady ? _petId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Mascota'),
                  items: [
                    for (final p in pets)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(
                          '${p.name} · ${p.speciesName ?? ''}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy ? null : (v) => _reset(() => _petId = v),
                  validator: (v) => v == null ? 'Elige la mascota' : null,
                ),
              ),
              KeyedSubtree(
                key: ValueKey('address-$addressReady'),
                child: DropdownButtonFormField<String>(
                  key: const Key('book-address'),
                  initialValue: addressReady ? _addressId : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Dirección'),
                  items: [
                    for (final a in addresses)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(
                          '${a.label} · ${a.communeName ?? a.streetText}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy ? null : (v) => _reset(() => _addressId = v),
                  validator: (v) => v == null ? 'Elige la dirección' : null,
                ),
              ),
              DropdownButtonFormField<int>(
                key: const Key('book-specialty'),
                initialValue: _specialtyId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Especialidad'),
                items: [
                  for (final s in specialties)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: busy ? null : (v) => _reset(() => _specialtyId = v),
                validator: (v) => v == null ? 'Elige la especialidad' : null,
              ),
              OutlinedButton.icon(
                key: const Key('book-date'),
                onPressed: busy ? null : _pickDate,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text('Día: ${formatDay(_date)}'),
              ),
              TextFormField(
                key: const Key('book-donation'),
                controller: _donation,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Donación extra (opcional)',
                  prefixText: r'$ ',
                  helperText: 'Va completa a tu fundación.',
                ),
                validator: validateDonation,
                onChanged: (_) => setState(() => _quote = null),
              ),
              FilledButton.icon(
                key: const Key('book-search'),
                onPressed: busy ? null : _search,
                icon: _searching
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: const Text('Ver veterinarios disponibles'),
              ),
            ],
          ),
        ),
        if (_error != null) ...[const SizedBox(height: 16), FormError(_error!)],
        if (_vets case final vets?) ...[
          const SizedBox(height: 16),
          if (vets.isEmpty)
            const EmptyState(
              key: Key('book-no-vets'),
              icon: Icons.event_busy_outlined,
              title: 'No hay horarios ese día.',
              message: 'Prueba otro día o en otra especialidad.',
            )
          else
            for (final v in vets)
              _VetSlots(
                vet: v,
                selected: _vetId == v.vetId ? _slot : null,
                enabled: !busy,
                onSelect: (slot) => _choose(v.vetId, slot),
              ),
        ],
        if (_quoting) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ],
        if (_quote case final q?) ...[
          const SizedBox(height: 16),
          QuoteBreakdown(quote: q),
          const SizedBox(height: 12),
          TextField(
            key: const Key('book-notes'),
            controller: _notes,
            maxLength: 300,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Motivo de la visita (opcional)',
              helperText: 'No incluyas datos de otras personas.',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Cancelación gratis hasta 2 horas antes. Después se cobra un '
            'cargo (simulado).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('book-confirm'),
            onPressed: busy ? null : _book,
            icon: const Icon(Icons.event_available_outlined),
            label: Text('Reservar ${formatSlot(_slot!)}'),
          ),
        ],
      ],
    );
  }
}

class _VetSlots extends StatelessWidget {
  const new({
    required this.vet,
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final AvailableVet vet;
  final DateTime? selected;
  final bool enabled;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      key: Key('vet-${vet.vetId}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(vet.displayName, style: t.titleMedium),
            VetRatingBadge(vetId: vet.vetId),
            Text('A unos ${formatKm(vet.distanceKm)}', style: t.bodySmall),
            if ((vet.bio ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(vet.bio!),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, s) in vet.slots.indexed)
                  ChoiceChip(
                    key: Key('slot-${vet.vetId}-$i'),
                    label: Text(formatHour(s)),
                    selected: selected == s,
                    onSelected: enabled ? (_) => onSelect(s) : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
