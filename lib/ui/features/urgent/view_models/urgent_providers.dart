import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show NotifierProviderFamily, StreamProviderFamily;
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/data/services/clock.dart';
import 'package:proyecto_felix/data/services/device_location.dart';
import 'package:proyecto_felix/data/services/live_location_service.dart';
import 'package:proyecto_felix/data/services/push_service.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/push.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

/// Hora actual que avanza cada segundo (cuentas regresivas).
final StreamProvider<DateTime> nowProvider =
    StreamProvider.autoDispose<DateTime>((ref) {
      final clock = ref.watch(clockProvider);
      return clock.every(const Duration(seconds: 1)).map((_) => clock.now());
    });

/// Hora para una cuenta regresiva (la del reloj mientras no llega un latido).
DateTime watchNow(WidgetRef ref) =>
    ref.watch(nowProvider).value ?? ref.read(clockProvider).now();

// ---------------------------------------------------------------------------
// Dueño
// ---------------------------------------------------------------------------

/// "Buscando vet": consulta `urgent_search_status` cada [poll]. Se eligió
/// refresco periódico y no Realtime porque la visita no se publica por
/// Realtime (solo la ubicación en vivo) y la consulta es liviana. Cuando la
/// búsqueda termina (aceptada, sin vet o cancelada) refresca `my_visits` y la
/// pantalla pasa al detalle correspondiente.
class UrgentSearchController extends Notifier<AsyncValue<UrgentSearchStatus>> {
  new(this.visitId);

  static const poll = Duration(seconds: 5);

  final String visitId;
  StreamSubscription<void>? _poll;
  bool _loading = false;

  @override
  AsyncValue<UrgentSearchStatus> build() {
    _poll = ref
        .watch(clockProvider)
        .every(poll)
        .listen((_) => unawaited(refresh()));
    ref
      ..onDispose(() => _poll?.cancel())
      ..listen(pushMessagesProvider, (_, next) {
        if (next.value?.visitId == visitId) unawaited(refresh());
      });
    unawaited(Future.microtask(refresh));
    return const AsyncLoading();
  }

  Future<void> refresh() async {
    if (_loading || !ref.mounted) return;
    _loading = true;
    try {
      final s = await ref.read(urgentRepositoryProvider).searchStatus(visitId);
      if (!ref.mounted) return;
      state = AsyncData(s);
      if (!s.isSearching) {
        ref.invalidate(myVisitsProvider);
        unawaited(_poll?.cancel());
        _poll = null;
      }
    } on Object catch (e, st) {
      // Un fallo puntual no borra el último estado conocido.
      if (ref.mounted && !state.hasValue) state = AsyncError(e, st);
    } finally {
      _loading = false;
    }
  }
}

final NotifierProviderFamily<
  UrgentSearchController,
  AsyncValue<UrgentSearchStatus>,
  String
>
urgentSearchProvider = NotifierProvider.autoDispose
    .family<UrgentSearchController, AsyncValue<UrgentSearchStatus>, String>(
      UrgentSearchController.new,
    );

/// Clínicas 24 h activas (opción cuando no hay vet).
final FutureProvider<List<EmergencyClinic>> emergencyClinicsProvider =
    FutureProvider.autoDispose<List<EmergencyClinic>>((ref) async {
      final all = await ref.watch(catalogRepositoryProvider).clinics();
      return all.where((c) => c.active).toList();
    });

/// Dueño: posición del vet en camino por el canal `visit:{id}`. Al dejar de
/// mirarla (llegó, cancelada o salió de la pantalla) se sale del canal. Si el
/// vet avisa que terminó, se refresca la visita.
///
/// O-F8-a: Realtime revisa la política solo al unirse, así que un vet que ya
/// estaba en el canal podría seguir enviando tras "llegó". Se ignoran las
/// posiciones que lleguen después de `end` o cuando la última vista conocida
/// de la visita ya no está `en_route`.
final StreamProviderFamily<LiveLocation, String> ownerLiveLocationProvider =
    StreamProvider.autoDispose.family<LiveLocation, String>((ref, visitId) {
      final session = ref.watch(liveLocationServiceProvider).join(visitId);
      ref.onDispose(() => unawaited(session.leave()));
      var ended = false;
      bool stillEnRoute() {
        final visits = ref.read(myVisitsProvider).value;
        final status = visits?.where((v) => v.id == visitId).firstOrNull;
        return status == null || status.status == VisitStatus.enRoute;
      }

      return session.events
          .where((e) {
            if (e is LiveEnded) {
              ended = true;
              ref.invalidate(myVisitsProvider);
              return false;
            }
            return e is LivePosition && !ended && stillEnRoute();
          })
          .map((e) => (e as LivePosition).location);
    });

// ---------------------------------------------------------------------------
// Vet
// ---------------------------------------------------------------------------

/// Origen de la posición enviada con la presencia.
enum PresenceSource { device, base }

@immutable
class VetPresence {
  const new({this.online = false, this.busy = false, this.error, this.source});

  final bool online;
  final bool busy;
  final String? error;
  final PresenceSource? source;
}

/// Interruptor "En línea": envía `set_vet_presence` cada [heartbeat] con la
/// posición del dispositivo o, si no hay, con el punto de partida. Al
/// apagarlo (o antes de cerrar sesión) envía `p_online = false`.
class VetPresenceController extends Notifier<VetPresence> {
  static const heartbeat = Duration(seconds: 30);

  StreamSubscription<void>? _beat;

  @override
  VetPresence build() {
    ref
      ..onDispose(_stopBeat)
      // Otra cuenta o sesión cerrada: deja de latir (el servidor deja de
      // considerar al vet a los 2 min sin latido).
      ..listen(sessionProvider, (_, next) {
        if (next.value is! SignedIn) {
          _stopBeat();
          state = const VetPresence();
        }
      });
    return const VetPresence();
  }

  void _stopBeat() {
    unawaited(_beat?.cancel());
    _beat = null;
  }

  Future<void> setOnline({required bool online}) =>
      online ? _goOnline() : goOffline();

  Future<void> _goOnline() async {
    state = VetPresence(online: state.online, busy: true);
    if (!await _send()) return;
    _stopBeat();
    _beat = ref
        .read(clockProvider)
        .every(heartbeat)
        .listen((_) => unawaited(_send()));
  }

  Future<GeoPoint?> _position(void Function(PresenceSource) source) async {
    final device = await ref.read(deviceLocationProvider).current();
    if (device != null) {
      source(PresenceSource.device);
      return device;
    }
    source(PresenceSource.base);
    return (await ref.read(vetAgendaRepositoryProvider).myBase())?.point;
  }

  /// Un latido. Devuelve false si no se pudo enviar.
  Future<bool> _send() async {
    try {
      var source = PresenceSource.device;
      final point = await _position((s) => source = s);
      if (point == null) {
        throw const VisitFailure(
          'Activa la ubicación del dispositivo o define tu punto de partida '
          'para recibir urgencias.',
        );
      }
      await ref
          .read(urgentRepositoryProvider)
          .setPresence(online: true, at: point);
      if (ref.mounted) state = VetPresence(online: true, source: source);
      return true;
    } on Object catch (e) {
      if (ref.mounted) {
        state = VetPresence(
          online: state.online,
          source: state.source,
          error: friendlyError(e),
        );
      }
      return false;
    }
  }

  /// Fuera de línea (también al cerrar sesión).
  Future<void> goOffline() async {
    final wasOnline = state.online || _beat != null;
    _stopBeat();
    if (!wasOnline) {
      state = const VetPresence();
      return;
    }
    state = VetPresence(online: state.online, busy: true);
    try {
      await ref.read(urgentRepositoryProvider).setPresence(online: false);
      if (ref.mounted) state = const VetPresence();
    } on Object catch (e) {
      if (ref.mounted) state = VetPresence(error: friendlyError(e));
    }
  }
}

final NotifierProvider<VetPresenceController, VetPresence> vetPresenceProvider =
    NotifierProvider<VetPresenceController, VetPresence>(
      VetPresenceController.new,
    );

/// Ofertas vigentes del vet en línea, refrescadas cada [poll] (y ante un
/// push `offer_*`, cuando exista).
class VetOffersController extends Notifier<AsyncValue<List<UrgentOffer>>> {
  static const poll = Duration(seconds: 5);

  bool _loading = false;

  @override
  AsyncValue<List<UrgentOffer>> build() {
    final online = ref.watch(vetPresenceProvider.select((p) => p.online));
    if (!online) return const AsyncData([]);
    final sub = ref
        .watch(clockProvider)
        .every(poll)
        .listen((_) => unawaited(refresh()));
    ref
      ..onDispose(sub.cancel)
      ..listen(pushMessagesProvider, (_, next) {
        if (next.value?.event
            case OfferNew() || OfferTaken() || OfferCancelled()) {
          unawaited(refresh());
        }
      });
    unawaited(Future.microtask(refresh));
    return const AsyncLoading();
  }

  Future<void> refresh() async {
    if (_loading || !ref.mounted) return;
    _loading = true;
    try {
      final offers = await ref.read(urgentRepositoryProvider).myOffers();
      if (ref.mounted) state = AsyncData(offers);
    } on Object catch (e, st) {
      if (ref.mounted && !state.hasValue) state = AsyncError(e, st);
    } finally {
      _loading = false;
    }
  }

  void _drop(UrgentOffer o) {
    final list = state.value;
    if (list == null) return;
    state = AsyncData([
      for (final x in list)
        if (x.offerId != o.offerId) x,
    ]);
  }

  /// Acepta. Si otro vet llegó antes lanza `OfferFailure` y la oferta se
  /// quita de la lista.
  Future<Visit> accept(UrgentOffer offer) async {
    try {
      final visit = await ref
          .read(urgentRepositoryProvider)
          .accept(offer.offerId);
      ref.invalidate(myVisitsProvider);
      if (ref.mounted) _drop(offer);
      return visit;
    } on VisitFailure {
      if (ref.mounted) _drop(offer);
      rethrow;
    }
  }

  Future<void> reject(UrgentOffer offer) async {
    await ref.read(urgentRepositoryProvider).reject(offer.offerId);
    if (ref.mounted) _drop(offer);
  }
}

final NotifierProvider<VetOffersController, AsyncValue<List<UrgentOffer>>>
vetOffersProvider = NotifierProvider.autoDispose(VetOffersController.new);

/// Estado de la ubicación compartida por el vet en camino.
@immutable
class LiveShare {
  const new({this.lastSent, this.noPosition = false, this.failed = false});

  final DateTime? lastSent;

  /// El dispositivo no entrega posición (permiso o servicio apagado).
  final bool noPosition;
  final bool failed;
}

/// Vet en camino: publica su posición cada [period] en `visit:{id}`. Al
/// dejar de usarse (llegó, canceló o salió de la pantalla) avisa al dueño y
/// sale del canal. No usa el punto de partida como respaldo: sería una
/// posición falsa.
class VetLiveSharing extends Notifier<LiveShare> {
  new(this.visitId);

  static const period = Duration(seconds: 5);

  final String visitId;
  LiveLocationSession? _session;

  @override
  LiveShare build() {
    final session = ref.watch(liveLocationServiceProvider).join(visitId);
    _session = session;
    final sub = ref
        .watch(clockProvider)
        .every(period)
        .listen((_) => unawaited(_tick()));
    ref.onDispose(() {
      unawaited(sub.cancel());
      unawaited(_close(session));
    });
    unawaited(Future.microtask(_tick));
    return const LiveShare();
  }

  static Future<void> _close(LiveLocationSession s) async {
    try {
      await s.sendEnd();
    } on Object {
      // Igual se sale del canal.
    }
    await s.leave();
  }

  Future<void> _tick() async {
    if (!ref.mounted) return;
    final point = await ref.read(deviceLocationProvider).current();
    if (!ref.mounted) return;
    if (point == null) {
      state = LiveShare(lastSent: state.lastSent, noPosition: true);
      return;
    }
    try {
      final now = ref.read(clockProvider).now();
      await _session?.send(LiveLocation(point, now));
      if (ref.mounted) state = LiveShare(lastSent: now);
    } on Object {
      if (ref.mounted) {
        state = LiveShare(lastSent: state.lastSent, failed: true);
      }
    }
  }
}

final NotifierProviderFamily<VetLiveSharing, LiveShare, String>
vetLiveSharingProvider = NotifierProvider.autoDispose
    .family<VetLiveSharing, LiveShare, String>(VetLiveSharing.new);
