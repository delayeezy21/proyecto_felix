import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;
import 'package:proyecto_felix/domain/models/rating.dart';
import 'package:proyecto_felix/domain/models/visit.dart' show formatSlot;
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/ratings/view_models/rating_providers.dart';
import 'package:proyecto_felix/ui/features/ratings/views/rating_widgets.dart';

Widget _error(WidgetRef ref, Object error, ProviderOrFamily provider) =>
    EmptyState(
      icon: Icons.cloud_off_outlined,
      title: 'No se pudo cargar.',
      message: friendlyError(error),
      isError: true,
      action: OutlinedButton.icon(
        onPressed: () => ref.invalidate(provider),
        icon: const Icon(Icons.refresh),
        label: const Text('Reintentar'),
      ),
    );

const _loading = Padding(
  padding: EdgeInsets.all(24),
  child: Center(child: CircularProgressIndicator(semanticsLabel: 'Cargando')),
);

/// Moderación de calificaciones: ocultar o mostrar el comentario (las
/// estrellas siguen contando). Queda en `admin_audit_log`.
class AdminRatingsTab extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ratings = ref.watch(adminRatingsProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(adminRatingsProvider.future),
      child: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Calificaciones',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const InfoBanner(
              icon: Icons.shield_outlined,
              message:
                  'Ocultar un comentario no borra la calificación: las '
                  'estrellas siguen contando en el promedio.',
            ),
            const SizedBox(height: 8),
            switch (ratings) {
              AsyncData(:final value) when value.isEmpty => const EmptyState(
                key: Key('admin-ratings-empty'),
                icon: Icons.star_border,
                title: 'Aún no hay calificaciones.',
              ),
              AsyncData(:final value) => Column(
                children: [for (final r in value) _RatingTile(rating: r)],
              ),
              AsyncError(:final error) => _error(
                ref,
                error,
                adminRatingsProvider,
              ),
              _ => _loading,
            },
          ],
        ),
      ),
    );
  }
}

class _RatingTile extends ConsumerWidget {
  const new({required this.rating});

  final AdminRating rating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = rating;
    final t = Theme.of(context).textTheme;
    final hasComment = (r.comment ?? '').isNotEmpty;
    return Card(
      key: Key('admin-rating-${r.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StarRatingDisplay(stars: r.stars),
                Text(
                  r.raterRole == 'owner'
                      ? 'Del dueño al veterinario'
                      : 'Del veterinario al dueño',
                  style: t.bodySmall,
                ),
                Text(
                  r.published ? 'Publicada' : 'Sin publicar',
                  style: t.labelMedium,
                ),
                if (r.hidden)
                  Text(
                    'Comentario oculto',
                    key: Key('admin-rating-hidden-${r.id}'),
                    style: t.labelMedium,
                  ),
              ],
            ),
            if (hasComment)
              Text(
                r.comment!,
                style: r.hidden
                    ? t.bodyMedium?.copyWith(
                        decoration: TextDecoration.lineThrough,
                      )
                    : t.bodyMedium,
              )
            else
              Text('Sin comentario.', style: t.bodySmall),
            if (r.createdAt != null)
              Text(formatSlot(r.createdAt!), style: t.bodySmall),
            if (hasComment)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: Key('admin-rating-toggle-${r.id}'),
                  onPressed: () => runWithFeedback(
                    context,
                    () => ref
                        .read(adminRatingsProvider.notifier)
                        .setHidden(r.id, hidden: !r.hidden),
                    success: r.hidden
                        ? 'Comentario visible'
                        : 'Comentario oculto',
                  ),
                  icon: Icon(
                    r.hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  label: Text(
                    r.hidden ? 'Mostrar comentario' : 'Ocultar comentario',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Alertas de vets con 3 o más cancelaciones en 30 días (HU7.4).
class AdminCancelAlertsTab extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<AdminCancelAlertsTab> createState() =>
      _AdminCancelAlertsTabState();
}

class _AdminCancelAlertsTabState extends ConsumerState<AdminCancelAlertsTab> {
  bool _includeReviewed = false;

  @override
  Widget build(BuildContext context) {
    final provider = cancelAlertsProvider(_includeReviewed);
    final alerts = ref.watch(provider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(provider.future),
      child: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Alertas de cancelación',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const InfoBanner(
              icon: Icons.event_busy_outlined,
              message:
                  'Se abre una alerta cuando un veterinario acumula 3 o más '
                  'cancelaciones en 30 días (incluye las que cerró el '
                  'sistema por no avanzar).',
            ),
            SwitchListTile(
              key: const Key('alerts-include-reviewed'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Mostrar también las revisadas'),
              value: _includeReviewed,
              onChanged: (v) => setState(() => _includeReviewed = v),
            ),
            switch (alerts) {
              AsyncData(:final value) when value.isEmpty => const EmptyState(
                key: Key('admin-alerts-empty'),
                icon: Icons.check_circle_outline,
                title: 'No hay alertas abiertas.',
              ),
              AsyncData(:final value) => Column(
                children: [
                  for (final a in value)
                    _AlertTile(alert: a, includeReviewed: _includeReviewed),
                ],
              ),
              AsyncError(:final error) => _error(ref, error, provider),
              _ => _loading,
            },
          ],
        ),
      ),
    );
  }
}

class _AlertTile extends ConsumerWidget {
  const new({required this.alert, required this.includeReviewed});

  final CancelAlert alert;
  final bool includeReviewed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = alert;
    final t = Theme.of(context).textTheme;
    return Card(
      key: Key('admin-alert-${a.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Text(a.vetName, style: t.titleMedium),
            Text(
              'Cancelaciones al abrir la alerta: ${a.cancelCount} · '
              'en los últimos 30 días: ${a.cancelCount30d}',
            ),
            if (a.lastCancelAt != null)
              Text(
                'Última cancelación: ${formatSlot(a.lastCancelAt!)}',
                style: t.bodySmall,
              ),
            if (a.reviewed)
              Text(
                'Revisada el ${formatSlot(a.reviewedAt!)}',
                key: Key('admin-alert-reviewed-${a.id}'),
                style: t.bodySmall,
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: Key('admin-alert-review-${a.id}'),
                  onPressed: () => runWithFeedback(
                    context,
                    () => ref
                        .read(cancelAlertsProvider(includeReviewed).notifier)
                        .review(a.id),
                    success: 'Alerta marcada como revisada',
                  ),
                  icon: const Icon(Icons.done),
                  label: const Text('Marcar revisada'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
