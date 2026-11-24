import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/views/quote_breakdown.dart';
import 'package:proyecto_felix/ui/features/urgent/views/live_location_widgets.dart';
import 'package:proyecto_felix/ui/features/urgent/views/urgent_search_view.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';
import 'package:proyecto_felix/ui/features/visits/views/visit_widgets.dart';

/// Busca la visita en la lista del usuario (la RLS ya filtra).
Widget _withVisit(
  WidgetRef ref,
  String visitId,
  String title,
  Widget Function(Visit visit) builder,
) => switch (ref.watch(myVisitsProvider)) {
  // Durante un refresco se mantiene la última lista (sin parpadeo ni salir
  // del canal de ubicación en vivo).
  AsyncValue(value: final value?) => switch (value.where(
    (v) => v.id == visitId,
  )) {
    final found when found.isNotEmpty => builder(found.first),
    _ => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const EmptyState(
        icon: Icons.search_off,
        title: 'No encontramos esta visita.',
      ),
    ),
  },
  AsyncError(:final error) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: EmptyState(
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
  _ => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: const LoadingView(),
  ),
};

/// Detalle de una visita para el dueño: estado, precio congelado, cancelar
/// y pagar al completarse.
class OwnerVisitView extends ConsumerWidget {
  const new({required this.visitId, super.key});

  final String visitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _withVisit(
    ref,
    visitId,
    'Visita',
    (v) => switch (v) {
      Visit(mode: VisitMode.urgent, status: VisitStatus.searching) =>
        UrgentSearchView(visit: v),
      Visit(status: VisitStatus.noVetFound) => NoVetFoundView(visit: v),
      _ => _Detail(visit: v),
    },
  );
}

class _Detail extends ConsumerWidget {
  const new({required this.visit});

  final Visit visit;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final fee = visit.cancelFeeNow ?? 0;
    final reason = await askReason(
      context,
      title: '¿Cancelar la visita?',
      message: fee > 0
          ? 'Faltan menos de 2 horas o el veterinario ya va en camino: '
                'se cobrará un cargo de ${formatClp(fee)} (simulado).'
          : 'Puedes cancelarla sin costo.',
      confirmLabel: fee > 0
          ? 'Cancelar y pagar ${formatClp(fee)}'
          : 'Cancelar visita',
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
      success: 'Visita cancelada',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = visit;
    final t = Theme.of(context).textTheme;
    // Cambios de la otra parte (vet en camino, llegó…) dentro de la app.
    if (v.status.isOpen) ref.watch(visitAutoRefreshProvider);
    final rows = <(IconData, String)>[
      if (v.scheduledAt != null)
        (Icons.event_outlined, formatSlot(v.scheduledAt!)),
      if (v.vetName != null) (Icons.medical_services_outlined, v.vetName!),
      if (v.petName != null)
        (Icons.pets, [v.petName!, ?v.speciesName].join(' · ')),
      if (v.specialtyName != null)
        (Icons.local_hospital_outlined, v.specialtyName!),
      if (v.addressLabel != null)
        (
          Icons.home_outlined,
          [v.addressLabel!, ?v.addressText, ?v.communeName].join(' · '),
        ),
    ];
    return FormPage(
      title: 'Visita',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: VisitStatusChip(status: v.status),
        ),
        const SizedBox(height: 12),
        for (final (icon, text) in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(icon),
            title: Text(text),
          ),
        if (v.status == VisitStatus.enRoute) ...[
          const SizedBox(height: 8),
          OwnerLiveMap(visitId: v.id),
          const SizedBox(height: 8),
        ],
        if (v.status == VisitStatus.pendingVet && v.confirmDeadline != null)
          InfoBanner(
            key: const Key('visit-deadline'),
            icon: Icons.hourglass_top_outlined,
            message:
                'El veterinario tiene hasta el '
                '${formatSlot(v.confirmDeadline!)} para confirmar. Si no '
                'responde, la solicitud expira sin costo.',
          ),
        if (v.status == VisitStatus.expired ||
            v.status == VisitStatus.rejected ||
            v.status == VisitStatus.cancelledVet)
          const InfoBanner(
            tone: BannerTone.warning,
            message:
                'Esta visita no se realizará y no tiene costo. Puedes '
                'agendar otra.',
          ),
        if (v.cancelFee > 0)
          InfoBanner(
            key: const Key('visit-cancel-fee'),
            tone: BannerTone.warning,
            message: 'Cargo por cancelación: ${formatClp(v.cancelFee)}.',
          ),
        if ((v.cancelReason ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Motivo: ${v.cancelReason}', style: t.bodySmall),
        ],
        if (v.closedBySystem) ...[
          const SizedBox(height: 8),
          Text(
            'Cerrada automáticamente por el sistema.',
            key: const Key('visit-closed-by-system'),
            style: t.bodySmall,
          ),
        ],
        if (v.quote != null) ...[
          const SizedBox(height: 16),
          QuoteBreakdown(quote: v.quote!, frozen: true),
        ],
        const SizedBox(height: 16),
        if (v.canPay)
          FilledButton.icon(
            key: const Key('visit-pay'),
            onPressed: () => context.push(AppRoutes.ownerVisitPay(v.id)),
            icon: const Icon(Icons.payments_outlined),
            label: Text('Pagar ${formatClp(v.quote?.total ?? 0)}'),
          ),
        if (v.paid)
          const InfoBanner(
            key: Key('visit-paid'),
            tone: BannerTone.success,
            icon: Icons.check_circle_outline,
            message: 'Pagada (simulado). ¡Gracias por tu aporte!',
          ),
        if (v.canCancel) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('visit-cancel'),
            onPressed: () => _cancel(context, ref),
            icon: const Icon(Icons.event_busy_outlined),
            label: Text(
              (v.cancelFeeNow ?? 0) > 0
                  ? 'Cancelar (cargo ${formatClp(v.cancelFeeNow!)})'
                  : 'Cancelar sin costo',
            ),
          ),
        ],
      ],
    );
  }
}

/// Pago simulado de una visita completada. No hay pasarela: el servidor
/// registra el pago con el precio congelado.
class VisitPaymentView extends ConsumerStatefulWidget {
  const new({required this.visitId, super.key});

  final String visitId;

  @override
  ConsumerState<VisitPaymentView> createState() => _VisitPaymentViewState();
}

class _VisitPaymentViewState extends ConsumerState<VisitPaymentView> {
  bool _busy = false;
  String? _error;
  bool? _paid;

  Future<void> _pay({required bool fail}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(visitRepositoryProvider)
          .pay(widget.visitId, simulateFailure: fail);
      ref.invalidate(myVisitsProvider);
      if (mounted) setState(() => _paid = r.paid);
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      _withVisit(ref, widget.visitId, 'Pagar visita', (v) {
        final total = v.quote?.total ?? 0;
        return FormPage(
          title: 'Pagar visita',
          children: [
            const InfoBanner(
              icon: Icons.science_outlined,
              message:
                  'Pago simulado: Felix no cobra dinero real ni pide datos '
                  'de tarjeta.',
            ),
            const SizedBox(height: 16),
            if (v.quote != null) QuoteBreakdown(quote: v.quote!, frozen: true),
            const SizedBox(height: 16),
            if (_paid == true || v.paid) ...[
              const InfoBanner(
                key: Key('pay-ok'),
                tone: BannerTone.success,
                icon: Icons.check_circle_outline,
                message: 'Pago registrado (simulado). ¡Gracias!',
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => context.pop(),
                child: const Text('Volver a la visita'),
              ),
            ] else ...[
              if (_paid == false)
                const InfoBanner(
                  key: Key('pay-failed'),
                  tone: BannerTone.error,
                  message: 'El pago simulado fue rechazado. Puedes reintentar.',
                ),
              if (_error != null) FormError(_error!),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('pay-confirm'),
                onPressed: _busy || !v.canPay ? null : () => _pay(fail: false),
                icon: const Icon(Icons.payments_outlined),
                label: Text('Pagar ${formatClp(total)} (simulado)'),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const Key('pay-fail'),
                onPressed: _busy || !v.canPay ? null : () => _pay(fail: true),
                child: const Text('Simular un pago rechazado'),
              ),
            ],
          ],
        );
      });
}
