import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/repositories/urgent_repository.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/urgent/view_models/urgent_providers.dart';

/// Vigencia de cada oferta (constante del servidor).
const _offerWindow = Duration(seconds: 60);

/// Urgencias del vet: interruptor "En línea" y ofertas vigentes.
class VetUrgentCard extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presence = ref.watch(vetPresenceProvider);
    final t = Theme.of(context).textTheme;
    final subtitle = switch (presence) {
      VetPresence(busy: true) => 'Actualizando…',
      VetPresence(online: true, source: PresenceSource.base) =>
        'Sin ubicación del dispositivo: usamos tu punto de partida.',
      VetPresence(online: true) =>
        'Compartes tu ubicación aproximada (unos 100 m) cada 30 s.',
      _ => 'Actívalo para recibir urgencias cercanas.',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Row(
              children: [
                const Icon(Icons.emergency_outlined),
                const SizedBox(width: 8),
                Expanded(child: Text('Urgencias', style: t.titleMedium)),
              ],
            ),
            SwitchListTile(
              key: const Key('vet-online'),
              contentPadding: EdgeInsets.zero,
              title: const Text('En línea'),
              subtitle: Text(subtitle),
              value: presence.online,
              onChanged: presence.busy
                  ? null
                  : (v) => ref
                        .read(vetPresenceProvider.notifier)
                        .setOnline(online: v),
            ),
            if (presence.error != null)
              InfoBanner(
                key: const Key('vet-online-error'),
                tone: BannerTone.error,
                message: presence.error!,
              ),
            if (presence.online) const _OfferList(),
          ],
        ),
      ),
    );
  }
}

class _OfferList extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = ref.watch(vetOffersProvider);
    final now = watchNow(ref);
    final live = (offers.value ?? const <UrgentOffer>[])
        .where((o) => !o.isExpiredAt(now))
        .toList();
    if (live.isEmpty) {
      return Text(
        offers.isLoading && !offers.hasValue
            ? 'Buscando urgencias…'
            : 'Sin urgencias por ahora. Si llega una, aparecerá aquí.',
        key: const Key('offers-empty'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [for (final o in live) OfferCard(offer: o, now: now)],
    );
  }
}

/// Oferta de urgencia: comuna, distancia aproximada, especie, especialidad y
/// cuánto recibe. Sin dirección ni coordenadas (llegan solo al aceptar).
class OfferCard extends ConsumerStatefulWidget {
  const new({required this.offer, required this.now, super.key});

  final UrgentOffer offer;
  final DateTime now;

  @override
  ConsumerState<OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends ConsumerState<OfferCard> {
  bool _busy = false;

  Future<void> _accept() async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(vetOffersProvider.notifier).accept(widget.offer);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Urgencia aceptada. Ya ves la dirección.'),
        ),
      );
      await router.push(AppRoutes.vetVisits);
    } on OfferFailure catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.kind == OfferFailureKind.taken
                ? 'Otro vet ya tomó esta urgencia'
                : e.message,
            key: Key('offer-failure-${e.kind.hint}'),
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(friendlyError(e), key: const Key('snack-error')),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    await runWithFeedback(
      context,
      () => ref.read(vetOffersProvider.notifier).reject(widget.offer),
      success: 'Urgencia rechazada',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    final t = Theme.of(context).textTheme;
    final left = o.expiresAt.difference(widget.now);
    final fraction = (left.inMilliseconds / _offerWindow.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    return Card.outlined(
      key: Key('offer-${o.offerId}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Text('Urgencia en ${o.communeName}', style: t.titleMedium),
            Text(
              [
                'A unos ${formatKm(o.distanceKm)}',
                o.speciesName,
                o.specialtyName,
              ].where((s) => s.isNotEmpty).join(' · '),
              key: Key('offer-approx-${o.offerId}'),
            ),
            if (o.vetPayout != null)
              Text('Recibes ${formatClp(o.vetPayout!)}', style: t.bodySmall),
            Text(
              'Quedan ${formatCountdown(o.expiresAt, widget.now)} para '
              'responder',
              key: Key('offer-countdown-${o.offerId}'),
              style: t.bodySmall,
            ),
            LinearProgressIndicator(
              value: fraction,
              semanticsLabel: 'Tiempo para responder la oferta',
            ),
            Text(
              'Verás la dirección exacta y el contacto solo si aceptas.',
              style: t.bodySmall,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: Key('offer-accept-${o.offerId}'),
                  onPressed: _busy ? null : _accept,
                  child: const Text('Aceptar'),
                ),
                OutlinedButton(
                  key: Key('offer-reject-${o.offerId}'),
                  onPressed: _busy ? null : _reject,
                  child: const Text('Rechazar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
