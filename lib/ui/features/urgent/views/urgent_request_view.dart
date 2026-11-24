import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

/// "Urgencia ahora": el dueño elige una mascota y una dirección propias. El
/// servidor valida que sean suyas, cotiza y avisa a los vets cercanos.
class UrgentRequestView extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<UrgentRequestView> createState() => _UrgentRequestViewState();
}

class _UrgentRequestViewState extends ConsumerState<UrgentRequestView> {
  final _form = GlobalKey<FormState>();
  final _notes = TextEditingController();
  String? _petId;
  String? _addressId;
  int? _specialtyId;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final visit = await ref
          .read(urgentRepositoryProvider)
          .request(
            petId: _petId!,
            addressId: _addressId!,
            specialtyId: _specialtyId,
            notes: _notes.text,
          );
      ref.invalidate(myVisitsProvider);
      if (!mounted) return;
      context.pushReplacement(AppRoutes.ownerVisit(visit.id));
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
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
    return FormPage(
      title: 'Urgencia ahora',
      children: [
        const InfoBanner(
          icon: Icons.emergency_outlined,
          message:
              'Avisamos a veterinarios cercanos en tandas (5, 10 y 20 km) '
              'durante hasta 10 minutos. Si nadie puede, no se cobra nada.',
        ),
        const SizedBox(height: 8),
        const InfoBanner(
          icon: Icons.lock_outline,
          message:
              'El veterinario verá tu dirección exacta solo cuando acepte. '
              'Antes solo ve la comuna y la distancia aproximada.',
        ),
        const SizedBox(height: 16),
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('urgent-pet'),
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
                onChanged: _busy ? null : (v) => setState(() => _petId = v),
                validator: (v) => v == null ? 'Elige la mascota' : null,
              ),
              DropdownButtonFormField<String>(
                key: const Key('urgent-address'),
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
                onChanged: _busy ? null : (v) => setState(() => _addressId = v),
                validator: (v) => v == null ? 'Elige la dirección' : null,
              ),
              DropdownButtonFormField<int>(
                key: const Key('urgent-specialty'),
                initialValue: _specialtyId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Especialidad (opcional)',
                  helperText: 'Si no eliges, se pide medicina general.',
                ),
                items: [
                  for (final s in specialties)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _specialtyId = v),
              ),
              TextField(
                key: const Key('urgent-notes'),
                controller: _notes,
                maxLength: 300,
                maxLines: 2,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '¿Qué le pasa? (opcional)',
                  helperText: 'No incluyas datos de otras personas.',
                ),
              ),
              Text(
                'Precio: tarifa base + recargo de urgencia + recargo por '
                'distancia. Al pedir verás el máximo; el precio final se fija '
                'cuando un veterinario acepta. Cancelación gratis hasta que '
                'el veterinario salga en camino.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_error != null) FormError(_error!),
              FilledButton.icon(
                key: const Key('urgent-submit'),
                onPressed: _busy ? null : _submit,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.emergency_outlined),
                label: const Text('Pedir urgencia ahora'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
