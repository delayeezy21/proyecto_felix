import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/rating.dart';
import 'package:proyecto_felix/domain/models/visit.dart' show formatDay;
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/ratings/view_models/rating_providers.dart';
import 'package:proyecto_felix/ui/features/ratings/views/rating_widgets.dart';

/// Cancelaciones en 30 días desde las que el servidor alerta al admin.
const cancelAlertThreshold = 3;

/// Perfil del vet: su promedio, las calificaciones recibidas (sin autor) y
/// sus cancelaciones en los últimos 30 días.
class VetRatingsCard extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final summary = ref.watch(myRatingSummaryProvider);
    final received = ref.watch(myRatingsReceivedProvider);
    return Card(
      key: const Key('vet-ratings-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text('Calificaciones y cumplimiento', style: t.titleMedium),
            switch (summary) {
              AsyncData(:final value) => _Summary(summary: value),
              AsyncError(:final error) => _Retry(
                message: friendlyError(error),
                onRetry: () => ref.invalidate(myRatingSummaryProvider),
              ),
              _ => const LinearProgressIndicator(),
            },
            const Divider(),
            Text('Calificaciones recibidas', style: t.titleSmall),
            switch (received) {
              AsyncData(:final value) when value.isEmpty => const Text(
                'Aún no tienes calificaciones publicadas.',
                key: Key('vet-ratings-empty'),
              ),
              AsyncData(:final value) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, r) in value.indexed)
                    _ReceivedTile(key: Key('vet-rating-$i'), rating: r),
                ],
              ),
              AsyncError(:final error) => _Retry(
                message: friendlyError(error),
                onRetry: () => ref.invalidate(myRatingsReceivedProvider),
              ),
              _ => const LinearProgressIndicator(),
            },
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const new({required this.summary});

  final RatingSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cancels = summary.cancelCount30d ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (summary.hasAverage)
          Row(
            key: const Key('vet-rating-avg'),
            spacing: 8,
            children: [
              Text(formatRating(summary.ratingAvg!), style: t.headlineSmall),
              StarRatingDisplay(stars: summary.ratingAvg!.round()),
              Text(
                '(${summary.ratingCount} '
                'calificaci${summary.ratingCount == 1 ? 'ón' : 'ones'})',
              ),
            ],
          )
        else
          Text(
            'Aún sin calificaciones suficientes (se muestra el promedio desde '
            '${summary.minRatings}).',
            key: const Key('vet-rating-few'),
          ),
        InfoBanner(
          key: const Key('vet-cancel-count'),
          tone: cancels >= cancelAlertThreshold
              ? BannerTone.warning
              : BannerTone.info,
          icon: Icons.event_busy_outlined,
          message:
              'Cancelaciones en los últimos 30 días: $cancels. Incluye las '
              'que cerró el sistema por no avanzar. Con '
              '$cancelAlertThreshold o más se genera una alerta para el '
              'administrador.',
        ),
      ],
    );
  }
}

class _ReceivedTile extends StatelessWidget {
  const new({required this.rating, super.key});

  final ReceivedRating rating;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: StarRatingDisplay(stars: rating.stars),
      subtitle: Text(
        [
          if (rating.commentHidden)
            'Comentario oculto por moderación.'
          else if ((rating.comment ?? '').isNotEmpty)
            rating.comment!,
          if (rating.publishedAt != null) formatDay(rating.publishedAt!),
        ].join('\n'),
        style: t.bodyMedium,
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  const new({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FormError(message),
      OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('Reintentar'),
      ),
    ],
  );
}

/// Al elegir veterinario: promedio público si tiene suficientes
/// calificaciones. Si falla o no hay promedio, no muestra nada.
class VetRatingBadge extends ConsumerWidget {
  const new({required this.vetId, super.key});

  final String vetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(vetRatingSummaryProvider(vetId)).value;
    final avg = s?.ratingAvg;
    if (s == null || avg == null) return const SizedBox.shrink();
    return Semantics(
      label:
          'Calificación ${formatRating(avg)} de 5, '
          '${s.ratingCount} calificaciones',
      excludeSemantics: true,
      child: Row(
        key: Key('vet-badge-$vetId'),
        spacing: 4,
        children: [
          StarRatingDisplay(stars: avg.round(), size: 16),
          Text(
            '${formatRating(avg)} (${s.ratingCount})',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
