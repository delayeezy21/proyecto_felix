import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/services/clock.dart';
import 'package:proyecto_felix/domain/models/rating.dart';
import 'package:proyecto_felix/domain/models/visit.dart' show formatSlot;
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/ratings/view_models/rating_providers.dart';

/// Estrellas de solo lectura con una sola etiqueta accesible
/// ("4 de 5 estrellas").
class StarRatingDisplay extends StatelessWidget {
  const new({required this.stars, this.size = 20, super.key});

  final int stars;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Semantics(
      container: true,
      label: starsLabel(stars),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              i <= stars ? Icons.star : Icons.star_border,
              size: size,
              color: color,
            ),
        ],
      ),
    );
  }
}

/// Selector de 1 a 5 estrellas: cada una es un botón de 48 × 48 con su
/// etiqueta ("3 de 5 estrellas") y estado seleccionado.
class StarRatingInput extends StatelessWidget {
  const new({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Wrap(
      children: [
        for (var i = 1; i <= 5; i++)
          Semantics(
            label: starsLabel(i),
            selected: value == i,
            button: true,
            excludeSemantics: true,
            child: IconButton(
              key: Key('rating-star-$i'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              iconSize: 32,
              color: color,
              onPressed: enabled ? () => onChanged(i) : null,
              icon: Icon(i <= value ? Icons.star : Icons.star_border),
            ),
          ),
      ],
    );
  }
}

/// Vet: abre la calificación de una visita completada en una hoja inferior
/// (su lista de visitas no tiene pantalla de detalle).
Future<void> showVisitRatingSheet(BuildContext context, String visitId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: VisitRatingCard(visitId: visitId),
        ),
      ),
    );

/// Tarjeta de calificación de una visita completada, para el dueño y el vet.
/// Muestra el formulario mientras se pueda calificar, "Tu calificación" y,
/// una vez publicada, "Su calificación".
class VisitRatingCard extends ConsumerStatefulWidget {
  const new({required this.visitId, super.key});

  final String visitId;

  @override
  ConsumerState<VisitRatingCard> createState() => _VisitRatingCardState();
}

class _VisitRatingCardState extends ConsumerState<VisitRatingCard> {
  final _comment = TextEditingController();
  int _stars = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(visitRatingProvider(widget.visitId).notifier)
          .rate(stars: _stars, comment: _comment.text);
    } on Object catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(visitRatingProvider(widget.visitId));
    final t = Theme.of(context).textTheme;
    return Card(
      key: const Key('visit-rating-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: switch (status) {
            AsyncValue(value: final s?) => _content(context, s, t),
            AsyncError(:final error) => [
              Text('Calificación', style: t.titleMedium),
              FormError(friendlyError(error)),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('rating-retry'),
                  onPressed: () =>
                      ref.invalidate(visitRatingProvider(widget.visitId)),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ),
            ],
            _ => [
              Text('Calificación', style: t.titleMedium),
              const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Cargando calificación',
                ),
              ),
            ],
          },
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, RatingStatus s, TextTheme t) {
    final other = s.isOwner ? 'el veterinario' : 'el dueño';
    final ofOther = s.isOwner ? 'del veterinario' : 'del dueño';
    final now = ref.read(clockProvider).now();
    final mine = s.mine;
    final theirs = s.theirs;
    return [
      if (mine == null && s.canRate) ...[
        Text('Calificar', style: t.titleMedium),
        Text(
          s.isOwner
              ? '¿Cómo fue la atención del veterinario?'
              : '¿Cómo fue la visita con el dueño?',
        ),
        if (s.rateUntil != null)
          Text(
            'Puedes calificar hasta el ${formatSlot(s.rateUntil!)}.',
            key: const Key('rating-until'),
            style: t.bodySmall,
          ),
        StarRatingInput(
          value: _stars,
          enabled: !_busy,
          onChanged: (v) => setState(() => _stars = v),
        ),
        TextField(
          key: const Key('rating-comment'),
          controller: _comment,
          enabled: !_busy,
          maxLength: ratingCommentMax,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(labelText: 'Comentario (opcional)'),
        ),
        const Text(
          'Tu calificación se mostrará cuando ambos califiquen o venza el '
          'plazo.',
        ),
        if (_error != null) FormError(_error!),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('rating-submit'),
            onPressed: _busy || _stars == 0 ? null : _submit,
            icon: const Icon(Icons.star_outline),
            label: const Text('Enviar calificación'),
          ),
        ),
      ] else if (mine == null) ...[
        Text('Calificación', style: t.titleMedium),
        if (s.expiredAt(now))
          InfoBanner(
            key: const Key('rating-expired'),
            message:
                'El plazo para calificar venció el '
                '${formatSlot(s.rateUntil!)}.',
          )
        else
          const InfoBanner(
            key: Key('rating-unavailable'),
            message: 'Esta visita ya no se puede calificar.',
          ),
      ] else ...[
        Text('Tu calificación', style: t.titleMedium),
        StarRatingDisplay(key: const Key('rating-mine'), stars: mine.stars),
        if (mine.hidden)
          Text(
            'El equipo de Felix ocultó tu comentario.',
            key: const Key('rating-mine-hidden'),
            style: t.bodySmall,
          )
        else if ((mine.comment ?? '').isNotEmpty)
          Text(mine.comment!),
      ],
      if (theirs != null) ...[
        const SizedBox(height: 8),
        Text('Su calificación', style: t.titleMedium),
        StarRatingDisplay(key: const Key('rating-theirs'), stars: theirs.stars),
        if (theirs.commentHidden)
          Text(
            'Comentario oculto por moderación.',
            key: const Key('rating-theirs-hidden'),
            style: t.bodySmall,
          )
        else if ((theirs.comment ?? '').isNotEmpty)
          Text(theirs.comment!),
      ] else if (mine != null &&
          (s.rateUntil == null || now.isBefore(s.rateUntil!)))
        InfoBanner(
          key: const Key('rating-pending'),
          icon: Icons.hourglass_top_outlined,
          message:
              'La calificación $ofOther se verá cuando ambos califiquen o '
              'venza el plazo'
              '${s.rateUntil == null ? '' : ' (${formatSlot(s.rateUntil!)})'}.',
        )
      else if (mine != null)
        Text(
          '${other[0].toUpperCase()}${other.substring(1)} no dejó '
          'calificación.',
          key: const Key('rating-theirs-none'),
          style: t.bodySmall,
        ),
    ];
  }
}
