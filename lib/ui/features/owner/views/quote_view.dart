import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/ui/core/app_dropdown.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/quote_providers.dart';
import 'package:proyecto_felix/ui/features/owner/views/quote_breakdown.dart';

/// Cotizar una visita: mascota, dirección, especialidad, tipo y fundación.
/// Solo muestra el precio calculado por el servidor; para reservar con un vet
/// y un horario se usa la pestaña Visitas (BookVisitView).
class QuotePanel extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<QuotePanel> createState() => _QuotePanelState();
}

class _QuotePanelState extends ConsumerState<QuotePanel> {
  final _formKey = GlobalKey<FormState>();
  final _donation = TextEditingController();
  String? _petId;
  String? _addressId;
  int? _specialtyId;
  VisitMode _mode = VisitMode.scheduled;
  String? _foundationId;
  bool _foundationTouched = false;

  @override
  void dispose() {
    _donation.dispose();
    super.dispose();
  }

  void _changed(VoidCallback fn) {
    setState(fn);
    ref.read(quoteProvider.notifier).clear();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref
        .read(quoteProvider.notifier)
        .request(
          QuoteRequest(
            petId: _petId!,
            addressId: _addressId!,
            specialtyId: _specialtyId!,
            mode: _mode,
            foundationId: _foundationId,
            extraDonation: parseDonation(_donation.text),
          ),
        );
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
    final foundations = ref.watch(foundationsProvider).value ?? const [];
    final profileFoundation = ref.watch(myFoundationIdProvider).value;
    final foundationReady =
        ref.watch(myFoundationIdProvider).hasValue &&
        ref.watch(foundationsProvider).hasValue;
    if (!_foundationTouched &&
        _foundationId == null &&
        profileFoundation != null &&
        foundations.any((f) => f.id == profileFoundation)) {
      _foundationId = profileFoundation;
    }
    final quote = ref.watch(quoteProvider);
    final loading = quote.isLoading;
    final defaultName = foundations
        .where((f) => f.isDefault)
        .map((f) => f.name)
        .firstOrNull;

    if (ref.watch(myPetsProvider).hasValue &&
        ref.watch(myAddressesProvider).hasValue &&
        (pets.isEmpty || addresses.isEmpty)) {
      return const SingleChildScrollView(
        child: EmptyState(
          key: Key('quote-missing-data'),
          icon: Icons.request_quote_outlined,
          title: 'Para cotizar necesitas una mascota y una dirección.',
          message: 'Agrégalas en las pestañas Mascotas y Direcciones.',
        ),
      );
    }

    return MaxWidth(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Cotiza una visita',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'El precio lo calcula Felix con las tarifas vigentes. '
            'Para reservar, ve a la pestaña Visitas.',
          ),
          const SizedBox(height: 16),
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                AppDropdown<String>(
                  key: const Key('quote-pet'),
                  initialValue: _petId,
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
                  onChanged: (v) => _changed(() => _petId = v),
                  validator: (v) => v == null ? 'Elige la mascota' : null,
                ),
                AppDropdown<String>(
                  key: const Key('quote-address'),
                  initialValue: _addressId,
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
                  onChanged: (v) => _changed(() => _addressId = v),
                  validator: (v) => v == null ? 'Elige la dirección' : null,
                ),
                AppDropdown<int>(
                  key: const Key('quote-specialty'),
                  initialValue: _specialtyId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Especialidad'),
                  items: [
                    for (final s in specialties)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (v) => _changed(() => _specialtyId = v),
                  validator: (v) => v == null ? 'Elige la especialidad' : null,
                ),
                SegmentedButton<VisitMode>(
                  key: const Key('quote-mode'),
                  segments: const [
                    ButtonSegment(
                      value: VisitMode.scheduled,
                      icon: Icon(Icons.event_outlined),
                      label: Text('Agendada'),
                    ),
                    ButtonSegment(
                      value: VisitMode.urgent,
                      icon: Icon(Icons.emergency_outlined),
                      label: Text('Urgencia'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => _changed(() => _mode = s.first),
                ),
                // Se reconstruye cuando llega la fundación del perfil.
                KeyedSubtree(
                  key: ValueKey('foundation-$foundationReady'),
                  child: AppDropdown<String?>(
                    key: const Key('quote-foundation'),
                    initialValue: _foundationId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Fundación que recibe el aporte',
                    ),
                    items: [
                      DropdownMenuItem<String?>(
                        child: Text(
                          defaultName == null
                              ? 'La fundación por defecto'
                              : 'Por defecto ($defaultName)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final f in foundations)
                        DropdownMenuItem<String?>(
                          value: f.id,
                          child: Text(f.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => _changed(() {
                      _foundationTouched = true;
                      _foundationId = v;
                    }),
                  ),
                ),
                TextFormField(
                  key: const Key('quote-donation-field'),
                  controller: _donation,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[0-9.]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Donación extra (opcional)',
                    prefixText: r'$ ',
                    helperText: 'Va completa a la fundación.',
                  ),
                  validator: validateDonation,
                  onChanged: (_) => ref.read(quoteProvider.notifier).clear(),
                ),
                FilledButton.icon(
                  key: const Key('quote-submit'),
                  onPressed: loading ? null : _submit,
                  icon: loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.request_quote_outlined),
                  label: const Text('Cotizar'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          switch (quote) {
            AsyncData(value: final q?) => QuoteBreakdown(quote: q),
            AsyncError(:final error) => Text(
              friendlyError(error),
              key: const Key('quote-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}
