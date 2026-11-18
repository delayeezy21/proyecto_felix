import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';
import 'package:proyecto_felix/ui/features/visits/views/visit_widgets.dart';

/// Visitas del vet: solicitudes por confirmar y su agenda. La dirección
/// exacta y el teléfono llegan solo si la visita está confirmada y activa.
class VetVisitsView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visits = ref.watch(myVisitsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mis visitas')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(myVisitsProvider.future),
        child: switch (visits) {
          AsyncData(:final value) => _List(visits: value),
          AsyncError(:final error) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: EmptyState(
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
          ),
          _ => const LoadingView(),
        },
      ),
    );
  }
}

class _List extends StatelessWidget {
  const new({required this.visits});

  final List<Visit> visits;

  @override
  Widget build(BuildContext context) {
    final pending = visits
        .where((v) => v.status == VisitStatus.pendingVet)
        .toList();
    final agenda =
        visits
            .where((v) => v.status.isOpen && v.status != VisitStatus.pendingVet)
            .toList()
          ..sort(
            (a, b) => (a.scheduledAt ?? DateTime(0)).compareTo(
              b.scheduledAt ?? DateTime(0),
            ),
          );
    final closed = visits.where((v) => !v.status.isOpen).toList();
    final t = Theme.of(context).textTheme;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(text, style: t.titleMedium),
    );
    return MaxWidth(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (visits.isEmpty)
            const EmptyState(
              key: Key('vet-visits-empty'),
              icon: Icons.event_outlined,
              title: 'Aún no tienes visitas.',
              message:
                  'Mantén al día tu horario y tu punto de partida para '
                  'aparecer en las búsquedas.',
            ),
          if (pending.isNotEmpty) ...[
            header('Solicitudes por confirmar'),
            for (final v in pending) _VisitCard(visit: v),
          ],
          if (agenda.isNotEmpty) ...[
            header('Próximas visitas'),
            for (final v in agenda) _VisitCard(visit: v),
          ],
          if (closed.isNotEmpty) ...[
            header('Historial'),
            for (final v in closed) _VisitCard(visit: v),
          ],
        ],
      ),
    );
  }
}

class _VisitCard extends ConsumerWidget {
  const new({required this.visit});

  final Visit visit;

  Future<void> _act(BuildContext context, WidgetRef ref, VetAction a) async {
    String? reason;
    if (a.destructive) {
      reason = await askReason(
        context,
        title: a.to == VisitStatus.rejected
            ? '¿Rechazar la solicitud?'
            : '¿Cancelar la visita?',
        message: a.to == VisitStatus.rejected
            ? 'Le avisaremos al dueño para que agende con otro veterinario.'
            : 'El dueño no paga nada. Las cancelaciones bajan tu tasa de '
                  'cumplimiento.',
        confirmLabel: a.label,
      );
      if (reason == null) return;
    }
    if (!context.mounted) return;
    await runWithFeedback(
      context,
      () => requestTransition(ref, visit.id, a.to, reason: reason),
      success: 'Listo: ${a.to.label.toLowerCase()}',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = visit;
    final t = Theme.of(context).textTheme;
    final km = v.distanceKm == null ? null : formatKm(v.distanceKm!);
    final exact = v.exact;
    return Card(
      key: Key('vet-visit-${v.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (v.scheduledAt != null)
                  Text(formatSlot(v.scheduledAt!), style: t.titleMedium),
                VisitStatusChip(status: v.status),
              ],
            ),
            Text([?v.petName, ?v.speciesName, ?v.specialtyName].join(' · ')),
            if (exact == null)
              Text(
                [?v.communeName, if (km != null) 'a unos $km'].join(' · '),
                key: Key('vet-visit-approx-${v.id}'),
              )
            else
              InfoBanner(
                key: Key('vet-visit-exact-${v.id}'),
                icon: Icons.location_on_outlined,
                message: [
                  exact.streetText,
                  ?exact.details,
                  ?v.communeName,
                  if (exact.ownerName != null) 'Contacto: ${exact.ownerName}',
                  ?exact.ownerPhone,
                ].join(' · '),
              ),
            if ((v.notes ?? '').isNotEmpty) Text('Motivo: ${v.notes}'),
            if (v.vetPayout != null)
              Text(
                'Recibes ${formatClp(v.vetPayout!)}'
                '${v.paid ? ' · pagada' : ''}',
                style: t.bodySmall,
              ),
            if (v.status == VisitStatus.pendingVet && v.confirmDeadline != null)
              Text(
                'Confirma antes del ${formatSlot(v.confirmDeadline!)}.',
                style: t.bodySmall,
              ),
            if ((v.cancelReason ?? '').isNotEmpty)
              Text('Motivo del cierre: ${v.cancelReason}', style: t.bodySmall),
            if (v.closedBySystem)
              Text(
                'Cerrada automáticamente por el sistema.',
                key: Key('vet-visit-system-${v.id}'),
                style: t.bodySmall,
              ),
            if (v.recordAccess && v.petId != null)
              Text(
                v.recordUntil == null
                    ? 'Acceso a la ficha mientras la visita esté activa.'
                    : 'Acceso a la ficha hasta el '
                          '${formatSlot(v.recordUntil!)}.',
                style: t.bodySmall,
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (v.recordAccess && v.petId != null)
                  OutlinedButton.icon(
                    key: Key('vet-record-${v.id}'),
                    onPressed: () =>
                        context.push(AppRoutes.vetRecord(v.petId!, v.id)),
                    icon: const Icon(Icons.medical_information_outlined),
                    label: Text(
                      v.recordWritable ? 'Ficha y registro' : 'Ver ficha',
                    ),
                  ),
                for (final a in vetActionsFor(v.status))
                  if (a.destructive)
                    OutlinedButton(
                      key: Key('vet-action-${v.id}-${a.to.wire}'),
                      onPressed: () => _act(context, ref, a),
                      child: Text(a.label),
                    )
                  else
                    FilledButton(
                      key: Key('vet-action-${v.id}-${a.to.wire}'),
                      onPressed: () => _act(context, ref, a),
                      child: Text(a.label),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
