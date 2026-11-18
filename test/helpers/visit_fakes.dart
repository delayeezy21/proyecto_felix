import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

import 'pricing_fakes.dart';

/// Visita de ejemplo vista por el dueño.
Visit ownerVisit({
  String id = 'vis1',
  VisitStatus status = VisitStatus.pendingVet,
  int? cancelFeeNow = 0,
  bool paid = false,
  int cancelFee = 0,
}) => Visit(
  id: id,
  isOwnerView: true,
  status: status,
  mode: VisitMode.scheduled,
  scheduledAt: DateTime(2026, 11, 20, 10, 30),
  confirmDeadline: DateTime(2026, 11, 19, 22),
  petName: 'Firulais',
  speciesName: 'Perro',
  specialtyName: 'Medicina general',
  communeName: 'Ñuñoa',
  vetName: 'Dra. Vera',
  addressLabel: 'Casa',
  addressText: 'Av. Ficticia 123',
  quote: sampleQuote(),
  cancelFeeNow: status.ownerCanCancel ? cancelFeeNow : null,
  paid: paid,
  cancelFee: cancelFee,
);

/// Visita de ejemplo vista por el vet. La dirección exacta solo llega si el
/// servidor la entrega ([exact]).
Visit vetVisit({
  String id = 'vis1',
  VisitStatus status = VisitStatus.pendingVet,
  bool exact = false,
}) => Visit(
  id: id,
  isOwnerView: false,
  status: status,
  mode: VisitMode.scheduled,
  scheduledAt: DateTime(2026, 11, 20, 10, 30),
  confirmDeadline: DateTime(2026, 11, 19, 22),
  petName: 'Firulais',
  speciesName: 'Perro',
  specialtyName: 'Medicina general',
  communeName: 'Ñuñoa',
  distanceKm: 8,
  servicePrice: 28490,
  vetPayout: 24216,
  exact: exact
      ? const VisitExactAddress(
          streetText: 'Av. Ficticia 123',
          details: 'Depto 4',
          point: GeoPoint(-33.4569, -70.5974),
          ownerName: 'Ana Ficticia',
          ownerPhone: '+56 9 1111 1111',
        )
      : null,
);

class FakeVisitRepository implements VisitRepository {
  List<Visit> visits = [];
  List<AvailableVet> vets = [];
  List<VisitStatusCount> summary = [];
  final searches = <(String, String, int, DateTime)>[];
  final bookings = <Map<String, Object?>>[];
  final transitions = <(String, VisitStatus, String?)>[];
  final payments = <(String, bool)>[];
  VisitFailure? nextFailure;

  /// Cargo que devuelve una cancelación del dueño.
  int cancelFee = 0;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  @override
  Future<List<AvailableVet>> availableVets({
    required String petId,
    required String addressId,
    required int specialtyId,
    required DateTime date,
  }) async {
    _maybeFail();
    searches.add((petId, addressId, specialtyId, date));
    return vets;
  }

  @override
  Future<Visit> book({
    required String quoteId,
    required String vetId,
    required String petId,
    required String addressId,
    required DateTime scheduledAt,
    String? notes,
  }) async {
    _maybeFail();
    bookings.add({
      'quote': quoteId,
      'vet': vetId,
      'pet': petId,
      'address': addressId,
      'at': scheduledAt,
      'notes': notes,
    });
    final v = ownerVisit(id: 'new1');
    visits = [v, ...visits];
    return v;
  }

  @override
  Future<List<Visit>> myVisits() async => List.of(visits);

  @override
  Future<int> transition(
    String visitId,
    VisitStatus to, {
    String? reason,
  }) async {
    _maybeFail();
    transitions.add((visitId, to, reason));
    final fee = to == VisitStatus.cancelledOwner ? cancelFee : 0;
    visits = [
      for (final v in visits)
        if (v.id == visitId && v.isOwnerView)
          ownerVisit(id: v.id, status: to, cancelFee: fee)
        else if (v.id == visitId)
          vetVisit(id: v.id, status: to, exact: to.isAssignedActive)
        else
          v,
    ];
    return fee;
  }

  @override
  Future<PaymentResult> pay(
    String visitId, {
    bool simulateFailure = false,
  }) async {
    _maybeFail();
    payments.add((visitId, simulateFailure));
    if (!simulateFailure) {
      visits = [
        for (final v in visits)
          if (v.id == visitId)
            ownerVisit(id: v.id, status: v.status, paid: true)
          else
            v,
      ];
    }
    return PaymentResult(paid: !simulateFailure, total: 30000);
  }

  @override
  Future<List<VisitStatusCount>> adminSummary({int days = 30}) async =>
      summary;
}

class FakeVetAgendaRepository implements VetAgendaRepository {
  VetBase? base;
  final timeOff = <TimeOff>[];
  final savedBases = <VetBase>[];

  @override
  Future<VetBase?> myBase() async => base;

  @override
  Future<void> saveBase(VetBase base) async {
    savedBases.add(base);
    this.base = base;
  }

  @override
  Future<List<TimeOff>> myTimeOff() async => List.of(timeOff);

  @override
  Future<void> addTimeOff(DateTime from, DateTime to) async =>
      timeOff.add(TimeOff(id: 't${timeOff.length + 1}', from: from, to: to));

  @override
  Future<void> removeTimeOff(String id) async =>
      timeOff.removeWhere((t) => t.id == id);
}
