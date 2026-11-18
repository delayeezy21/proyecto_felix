import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

/// Resumen de visitas de los últimos 30 días: solo conteos por tipo y estado.
/// El admin no ve dueños, mascotas, direcciones ni montos de cada visita.
class AdminVisitsTab extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(adminVisitSummaryProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(adminVisitSummaryProvider.future),
      child: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Visitas (últimos 30 días)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const InfoBanner(
              icon: Icons.lock_outline,
              message:
                  'Solo totales por estado. Los datos de cada visita los ven '
                  'únicamente el dueño y el veterinario asignado.',
            ),
            const SizedBox(height: 8),
            switch (summary) {
              AsyncData(:final value) when value.isEmpty => const EmptyState(
                key: Key('admin-visits-empty'),
                icon: Icons.event_outlined,
                title: 'Sin visitas en el período.',
              ),
              AsyncData(:final value) => Column(
                children: [
                  for (final r in value)
                    ListTile(
                      key: Key('admin-visits-${r.mode.wire}-${r.status.wire}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(r.status.label),
                      subtitle: Text(r.mode.label),
                      trailing: Text(
                        '${r.total}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                ],
              ),
              AsyncError(:final error) => EmptyState(
                icon: Icons.cloud_off_outlined,
                title: 'No se pudo cargar.',
                message: friendlyError(error),
                isError: true,
              ),
              _ => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            },
          ],
        ),
      ),
    );
  }
}
