import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';
import 'package:proyecto_felix/ui/features/visits/views/visit_widgets.dart';

/// Pestaña "Visitas" del dueño: sus visitas y el acceso a agendar.
class OwnerVisitsTab extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = FilledButton.icon(
      key: const Key('visit-book'),
      onPressed: () => context.push(AppRoutes.ownerBook),
      icon: const Icon(Icons.event_available_outlined),
      label: const Text('Agendar visita'),
    );
    final scheme = Theme.of(context).colorScheme;
    final urgent = FilledButton.icon(
      key: const Key('visit-urgent'),
      style: FilledButton.styleFrom(
        backgroundColor: scheme.error,
        foregroundColor: scheme.onError,
      ),
      onPressed: () => context.push(AppRoutes.ownerUrgent),
      icon: const Icon(Icons.emergency_outlined),
      label: const Text('Urgencia ahora'),
    );
    final visits = ref.watch(myVisitsProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(myVisitsProvider.future),
      child: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Mis visitas',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Wrap(spacing: 8, runSpacing: 8, children: [urgent, book]),
                ],
              ),
            ),
            switch (visits) {
              AsyncData(:final value) when value.isEmpty => const EmptyState(
                key: Key('visits-empty'),
                icon: Icons.event_outlined,
                title: 'Aún no tienes visitas.',
                message:
                    'Agenda una visita a domicilio con un veterinario '
                    'verificado.',
              ),
              AsyncData(:final value) => Column(
                children: [for (final v in value) _VisitTile(visit: v)],
              ),
              AsyncError(:final error) => EmptyState(
                icon: Icons.cloud_off_outlined,
                title: 'No se pudo cargar.',
                message: friendlyError(error),
                isError: true,
                action: OutlinedButton.icon(
                  onPressed: () => ref.invalidate(myVisitsProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ),
              _ => const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            },
          ],
        ),
      ),
    );
  }
}

class _VisitTile extends StatelessWidget {
  const new({required this.visit});

  final Visit visit;

  @override
  Widget build(BuildContext context) {
    final v = visit;
    final when = v.scheduledAt == null ? '' : formatSlot(v.scheduledAt!);
    final subtitle = [
      ?v.petName,
      ?v.vetName,
      if (v.quote != null) formatClp(v.quote!.total),
      if (v.canPay) 'Pendiente de pago',
    ].join(' · ');
    return ListTile(
      key: Key('visit-${v.id}'),
      leading: Icon(
        v.mode == VisitMode.urgent
            ? Icons.emergency_outlined
            : Icons.event_note_outlined,
        semanticLabel: v.mode.label,
      ),
      title: Text(when.isEmpty ? v.status.label : when),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle.isNotEmpty) Text(subtitle),
          const SizedBox(height: 4),
          VisitStatusChip(status: v.status),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(AppRoutes.ownerVisit(v.id)),
    );
  }
}
