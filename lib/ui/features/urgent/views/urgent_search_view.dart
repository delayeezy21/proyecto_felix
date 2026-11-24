import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/owner/views/quote_breakdown.dart';
import 'package:proyecto_felix/ui/features/urgent/view_models/urgent_providers.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';
import 'package:proyecto_felix/ui/features/visits/views/visit_widgets.dart';

/// Ventana de búsqueda (constante del servidor, `private.urgent_rules()`).
const _searchWindow = Duration(minutes: 10);

List<(IconData, String)> _visitRows(Visit v) => [
  if (v.petName != null) (Icons.pets, [v.petName!, ?v.speciesName].join(' · ')),
  if (v.specialtyName != null)
    (Icons.local_hospital_outlined, v.specialtyName!),
  if (v.addressLabel != null)
    (
      Icons.home_outlined,
      [v.addressLabel!, ?v.addressText, ?v.communeName].join(' · '),
    ),
];

Widget _rows(Visit v) => Column(
  children: [
    for (final (icon, text) in _visitRows(v))
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(icon),
        title: Text(text),
      ),
  ],
);

/// "Buscando vet": radio actual, tanda, vets revisando y cuenta regresiva
/// hasta `search_until`. Al terminar la búsqueda, la pantalla de la visita
/// cambia sola (aceptada → detalle; sin vet → opciones).
class UrgentSearchView extends ConsumerWidget {
  const new({required this.visit, super.key});

  final Visit visit;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final reason = await askReason(
      context,
      title: '¿Cancelar la urgencia?',
      message: 'Aún no hay veterinario asignado: puedes cancelarla sin costo.',
      confirmLabel: 'Cancelar urgencia',
    );
    if (reason == null || !context.mounted) return;
    await runWithFeedback(
      context,
      () => requestTransition(
        ref,
        visit.id,
        VisitStatus.cancelledOwner,
        reason: reason,
      ),
      success: 'Urgencia cancelada',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final status = ref.watch(urgentSearchProvider(visit.id));
    final s = status.value;
    final now = watchNow(ref);
    final until = s?.searchUntil ?? visit.confirmDeadline;
    final left = until?.difference(now) ?? Duration.zero;
    final fraction = left.isNegative
        ? 0.0
        : (left.inMilliseconds / _searchWindow.inMilliseconds).clamp(0.0, 1.0);
    final radius = s?.radiusKm;
    return FormPage(
      title: 'Urgencia',
      children: [
        const InfoBanner(
          key: Key('urgent-searching'),
          icon: Icons.radar_outlined,
          liveRegion: true,
          title: 'Buscando veterinario',
          message:
              'Avisamos a veterinarios cercanos. Te mostraremos quién acepta '
              'apenas ocurra.',
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                Text(
                  until == null
                      ? 'Buscando…'
                      : left.isNegative || left == Duration.zero
                      ? 'Terminando la búsqueda…'
                      : 'Quedan ${formatCountdown(until, now)} de búsqueda',
                  key: const Key('urgent-countdown'),
                  style: t.titleMedium,
                ),
                LinearProgressIndicator(
                  value: fraction,
                  semanticsLabel: 'Tiempo de búsqueda restante',
                ),
                Text(
                  radius == null
                      ? 'Preparando la primera tanda…'
                      : 'Radio actual: ${formatKm(radius)}',
                  key: const Key('urgent-radius'),
                ),
                if (s != null && s.batches > 0)
                  Text(
                    'Tanda ${s.batches}: '
                    '${switch (s.pendingOffers) {
                      0 => 'buscando más veterinarios',
                      1 => '1 veterinario revisando tu solicitud',
                      final n => '$n veterinarios revisando tu solicitud',
                    }}',
                    key: const Key('urgent-batch'),
                  ),
                if (status case AsyncError(:final error) when s == null)
                  FormError(friendlyError(error)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _rows(visit),
        if (visit.quote != null) ...[
          const SizedBox(height: 8),
          QuoteBreakdown(quote: visit.quote!, frozen: true),
        ],
        const SizedBox(height: 16),
        if (visit.canCancel)
          OutlinedButton.icon(
            key: const Key('urgent-cancel'),
            onPressed: () => _cancel(context, ref),
            icon: const Icon(Icons.close),
            label: const Text('Cancelar sin costo'),
          ),
      ],
    );
  }
}

/// Sin vet disponible: no hay cobro. Ofrece agendar la primera hora libre
/// (flujo agendado) o ver clínicas 24 h.
class NoVetFoundView extends ConsumerWidget {
  const new({required this.visit, super.key});

  final Visit visit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addresses = ref.watch(myAddressesProvider).value ?? const [];
    // QA-F8-04: la dirección de la urgencia por su id (no por etiqueta y
    // calle, que pueden repetirse), solo si sigue activa.
    final addressId = addresses.any((a) => a.active && a.id == visit.addressId)
        ? visit.addressId
        : null;
    return FormPage(
      title: 'Urgencia',
      children: [
        const InfoBanner(
          key: Key('no-vet-found'),
          tone: BannerTone.warning,
          icon: Icons.search_off,
          liveRegion: true,
          title: 'No encontramos veterinario disponible',
          message:
              'Ningún veterinario cercano pudo tomar tu urgencia. No se hizo '
              'ningún cobro.',
        ),
        const SizedBox(height: 8),
        _rows(visit),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('no-vet-schedule'),
          onPressed: () => context.push(
            AppRoutes.ownerBookFrom(petId: visit.petId, addressId: addressId),
          ),
          icon: const Icon(Icons.event_available_outlined),
          label: const Text('Agendar primera hora libre'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('no-vet-clinics'),
          onPressed: () =>
              context.push(AppRoutes.ownerClinicsNear(visit.communeName)),
          icon: const Icon(Icons.local_hospital_outlined),
          label: const Text('Clínicas 24 h'),
        ),
        const SizedBox(height: 12),
        Text(
          'Si es una emergencia grave, llama o acude de inmediato a una '
          'clínica 24 h.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
