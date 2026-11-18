import 'package:flutter/material.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/pricing.dart';

/// Desglose del precio cotizado por el servidor. Solo muestra montos que ya
/// vienen calculados (la app nunca recalcula el precio).
class QuoteBreakdown extends StatelessWidget {
  const new({required this.quote, this.frozen = false, super.key});

  final Quote quote;

  /// Precio ya congelado en una visita (no muestra la vigencia).
  final bool frozen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = quote;
    final time = TimeOfDay.fromDateTime(q.expiresAt).format(context);
    return Card(
      key: const Key('quote-breakdown'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Desglose del precio', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _Line('Tarifa base', q.basePrice, key: const Key('quote-base')),
            if (q.urgentSurcharge > 0)
              _Line(
                'Recargo por urgencia',
                q.urgentSurcharge,
                key: const Key('quote-urgent'),
              ),
            if (q.distancePending)
              const _TextLine(
                'Recargo por distancia',
                'Se calcula al asignar veterinario',
                key: Key('quote-distance-pending'),
              )
            else
              _Line(
                q.billableKm == 0
                    ? 'Distancia (${_km(q.distanceKm!)}, sin recargo)'
                    : 'Recargo por distancia (${q.billableKm} km adicionales)',
                q.distanceSurcharge,
                key: const Key('quote-distance'),
              ),
            if (q.discount > 0)
              _Line('Descuento', -q.discount, key: const Key('quote-discount')),
            const Divider(height: 24),
            _Line(
              'Precio del servicio',
              q.servicePrice,
              key: const Key('quote-service'),
            ),
            if (q.extraDonation > 0)
              _Line(
                'Donación extra a ${q.foundationName}',
                q.extraDonation,
                key: const Key('quote-donation'),
              ),
            const SizedBox(height: 4),
            _Line(
              'Total',
              q.total,
              key: const Key('quote-total'),
              emphasis: true,
            ),
            const Divider(height: 24),
            Text('¿A dónde va tu pago?', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            _Line('Veterinario/a', q.vetPayout, key: const Key('quote-vet')),
            _Line(
              'Comisión de Felix',
              q.platformFee - q.foundationShare,
              key: const Key('quote-platform'),
            ),
            _Line(
              'Aporte a ${q.foundationName}',
              q.foundationShare + q.extraDonation,
              key: const Key('quote-foundation'),
            ),
            const SizedBox(height: 12),
            Text(
              '${frozen ? 'Precio congelado al reservar.' : 'Precio calculado '
                        'por Felix y válido hasta las $time.'} '
              'Pago simulado: no se cobra dinero real.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _km(double km) =>
      '${km.toStringAsFixed(km % 1 == 0 ? 0 : 1).replaceAll('.', ',')} km';
}

class _Line extends StatelessWidget {
  const new(this.label, this.amount, {this.emphasis = false, super.key});

  final String label;
  final int amount;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = emphasis
        ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 12),
          Text(formatClp(amount), style: style),
        ],
      ),
    );
  }
}

class _TextLine extends StatelessWidget {
  const new(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
