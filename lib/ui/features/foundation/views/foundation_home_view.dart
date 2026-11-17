import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';
import 'package:proyecto_felix/ui/features/foundation/view_models/foundation_providers.dart';

/// Panel de la fundación: total recibido y detalle por mes (solo agregados,
/// sin datos de los dueños: Ley 21.719).
class FoundationHomeView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foundation = ref.watch(memberFoundationProvider);
    final summary = ref.watch(foundationSummaryProvider);
    void retry() => ref
      ..invalidate(memberFoundationProvider)
      ..invalidate(foundationSummaryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(foundation.value?.name ?? 'Fundación'),
        actions: [
          IconButton(
            key: const Key('sign-out'),
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      body: switch ((foundation, summary)) {
        (AsyncData(value: null), _) => const SingleChildScrollView(
          child: EmptyState(
            key: Key('foundation-no-membership'),
            icon: Icons.volunteer_activism_outlined,
            title: 'Tu cuenta no está asociada a una fundación activa.',
            message: 'Contacta al administrador de Felix.',
          ),
        ),
        (AsyncData(), AsyncData(value: final months)) => RefreshIndicator(
          onRefresh: () => ref.refresh(foundationSummaryProvider.future),
          child: _SummaryList(months: months),
        ),
        (AsyncError(:final error), _) ||
        (_, AsyncError(:final error)) => SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'No se pudo cargar.',
            message: friendlyError(error),
            isError: true,
            action: OutlinedButton.icon(
              onPressed: retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

class _SummaryList extends StatelessWidget {
  const new({required this.months});

  final List<FoundationMonth> months;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = summaryTotals(months);
    return MaxWidth(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Aportes recibidos (últimos 12 meses)',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatClp(totals.total),
                    key: const Key('foundation-total'),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Comisiones: ${formatClp(totals.commission)} · '
                    'Donaciones: ${formatClp(totals.donation)}',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const InfoBanner(
            icon: Icons.lock_outline,
            message:
                'Solo ves totales por mes. Felix no comparte nombres ni datos '
                'de quienes aportan. Los pagos son simulados.',
          ),
          const SizedBox(height: 16),
          Text('Detalle por mes', style: theme.textTheme.titleMedium),
          if (months.isEmpty)
            const EmptyState(
              key: Key('foundation-empty'),
              icon: Icons.savings_outlined,
              title: 'Aún no hay aportes.',
              message: 'Aparecerán aquí cuando se paguen visitas.',
            )
          else
            for (final m in months)
              ListTile(
                key: Key('foundation-month-${m.month.year}-${m.month.month}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_month_outlined),
                title: Text(_capitalize(monthLabel(m.month))),
                subtitle: Text(
                  'Comisiones ${formatClp(m.commissionTotal)} · '
                  'Donaciones ${formatClp(m.donationTotal)}',
                ),
                trailing: Text(
                  formatClp(m.total),
                  style: theme.textTheme.titleMedium,
                ),
              ),
        ],
      ),
    );
  }

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
