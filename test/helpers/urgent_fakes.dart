import 'dart:async';

import 'package:proyecto_felix/data/repositories/urgent_repository.dart';
import 'package:proyecto_felix/data/services/clock.dart';
import 'package:proyecto_felix/data/services/device_location.dart';
import 'package:proyecto_felix/data/services/live_location_service.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

import 'pricing_fakes.dart';
import 'visit_fakes.dart';

/// Reloj manual: la hora no avanza sola y los latidos salen solo con
/// [fire]. Así los tests no dependen del tiempo real ni dejan timers.
class ManualClock implements AppClock {
  new([DateTime? start]) : current = start ?? DateTime(2026, 11, 24, 12);

  DateTime current;
  final _ticks = StreamController<Duration>.broadcast(sync: true);

  @override
  DateTime now() => current;

  @override
  Stream<void> every(Duration period) =>
      _ticks.stream.where((p) => p == period).map((_) {});

  /// Emite un latido a quienes escuchan cada [period].
  void fire(Duration period) => _ticks.add(period);

  /// Avanza la hora y emite el latido de 1 s (cuentas regresivas).
  void advance(Duration by) {
    current = current.add(by);
    fire(const Duration(seconds: 1));
  }
}

/// Urgencia vista por el dueño.
Visit urgentOwnerVisit({
  String id = 'urg1',
  VisitStatus status = VisitStatus.searching,
  DateTime? searchUntil,
}) {
  final q = sampleQuote();
  return Visit(
    id: id,
    isOwnerView: true,
    status: status,
    mode: VisitMode.urgent,
    confirmDeadline: searchUntil ?? DateTime(2026, 11, 24, 12, 10),
    petId: 'p1',
    petName: 'Firulais',
    speciesName: 'Perro',
    specialtyName: 'Medicina general',
    communeName: 'Ñuñoa',
    addressLabel: 'Casa',
    addressText: 'Av. Ficticia 123',
    vetName: status == VisitStatus.searching ? null : 'Dra. Vera',
    scheduledAt: status.isAssignedActive ? DateTime(2026, 11, 24, 12, 3) : null,
    quote: Quote(
      id: q.id,
      mode: VisitMode.urgent,
      basePrice: q.basePrice,
      urgentSurcharge: 8097,
      billableKm: 0,
      distanceSurcharge: 0,
      discount: 0,
      servicePrice: q.basePrice + 8097,
      platformFee: q.platformFee,
      foundationShare: q.foundationShare,
      vetPayout: q.vetPayout,
      extraDonation: 0,
      total: q.basePrice + 8097,
      foundationName: q.foundationName,
      expiresAt: q.expiresAt,
      maxServicePrice: 43087,
      maxTotal: 43087,
      maxDistanceKm: 20,
    ),
    cancelFeeNow: status.ownerCanCancel ? 0 : null,
  );
}

UrgentOffer sampleOffer({
  String id = 'off1',
  DateTime? expiresAt,
  String visitId = 'urg1',
}) => UrgentOffer(
  offerId: id,
  visitId: visitId,
  batch: 1,
  createdAt: DateTime(2026, 11, 24, 12),
  expiresAt: expiresAt ?? DateTime(2026, 11, 24, 12, 1),
  communeName: 'Ñuñoa',
  distanceKm: 3.5,
  speciesName: 'Perro',
  specialtyName: 'Medicina general',
  servicePrice: 35087,
  vetPayout: 29824,
);

class FakeUrgentRepository implements UrgentRepository {
  final requests = <Map<String, Object?>>[];
  final presence = <(bool, GeoPoint?)>[];
  final accepted = <String>[];
  final rejected = <String>[];
  final statusCalls = <String>[];
  List<UrgentOffer> offers = [];
  UrgentSearchStatus? status;
  Exception? nextFailure;
  OfferFailureKind? acceptFailure;

  /// Lista del repositorio de visitas que se actualiza al pedir/aceptar.
  FakeVisitRepository? visits;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  @override
  Future<Visit> request({
    required String petId,
    required String addressId,
    int? specialtyId,
    String? foundationId,
    int extraDonation = 0,
    String? notes,
  }) async {
    _maybeFail();
    requests.add({
      'pet': petId,
      'address': addressId,
      'specialty': specialtyId,
      'notes': notes,
    });
    final v = urgentOwnerVisit();
    visits?.visits = [v, ...?visits?.visits];
    return v;
  }

  @override
  Future<UrgentSearchStatus> searchStatus(String visitId) async {
    _maybeFail();
    statusCalls.add(visitId);
    return status ??
        UrgentSearchStatus(
          visitId: visitId,
          status: VisitStatus.searching,
          searchUntil: DateTime(2026, 11, 24, 12, 10),
          batches: 0,
          pendingOffers: 0,
        );
  }

  @override
  Future<void> setPresence({required bool online, GeoPoint? at}) async {
    _maybeFail();
    presence.add((online, at));
  }

  @override
  Future<List<UrgentOffer>> myOffers() async {
    _maybeFail();
    return List.of(offers);
  }

  @override
  Future<Visit> accept(String offerId) async {
    _maybeFail();
    final kind = acceptFailure;
    if (kind != null) throw OfferFailure(kind);
    accepted.add(offerId);
    offers = [
      for (final o in offers)
        if (o.offerId != offerId) o,
    ];
    final v = vetVisit(id: 'urg1', status: VisitStatus.accepted, exact: true);
    visits?.visits = [v, ...?visits?.visits];
    return v;
  }

  @override
  Future<void> reject(String offerId) async {
    _maybeFail();
    rejected.add(offerId);
    offers = [
      for (final o in offers)
        if (o.offerId != offerId) o,
    ];
  }
}

class FakeLiveSession implements LiveLocationSession {
  final controller = StreamController<LiveEvent>.broadcast(sync: true);
  final sent = <LiveLocation>[];
  bool ended = false;
  bool left = false;

  @override
  Stream<LiveEvent> get events => controller.stream;

  @override
  Future<void> send(LiveLocation location) async => sent.add(location);

  @override
  Future<void> sendEnd() async => ended = true;

  @override
  Future<void> leave() async {
    left = true;
    await controller.close();
  }
}

class FakeLiveLocationService implements LiveLocationService {
  final sessions = <String, List<FakeLiveSession>>{};

  FakeLiveSession? last(String visitId) => sessions[visitId]?.last;

  @override
  LiveLocationSession join(String visitId) {
    final s = FakeLiveSession();
    (sessions[visitId] ??= []).add(s);
    return s;
  }
}

class FakeDeviceLocation implements DeviceLocation {
  GeoPoint? point = const GeoPoint(-33.45, -70.6);
  int calls = 0;

  @override
  Future<GeoPoint?> current() async {
    calls++;
    return point;
  }
}
