import 'package:proyecto_felix/data/repositories/pricing_repository.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';

/// Cotización de ejemplo del SPEC: $30.000 → comisión 4.500, fundación 900,
/// vet 25.500.
Quote sampleQuote({
  VisitMode mode = VisitMode.scheduled,
  int base = 30000,
  int urgent = 0,
  int billableKm = 0,
  int distance = 0,
  int discount = 0,
  int fee = 4500,
  int share = 900,
  int donation = 0,
  double? distanceKm,
  String foundation = 'Fundación Demo Patitas',
}) {
  final service = base - discount + urgent + distance;
  return Quote(
    id: 'q1',
    mode: mode,
    basePrice: base,
    urgentSurcharge: urgent,
    billableKm: billableKm,
    distanceSurcharge: distance,
    discount: discount,
    servicePrice: service,
    platformFee: fee,
    foundationShare: share,
    vetPayout: service - fee,
    extraDonation: donation,
    total: service + donation,
    foundationName: foundation,
    expiresAt: DateTime(2026, 11, 17, 18, 30),
    distanceKm: distanceKm,
  );
}

/// Cotizador falso: registra las solicitudes y responde lo configurado.
class FakeQuoteRepository implements QuoteRepository {
  final requests = <QuoteRequest>[];
  Quote Function(QuoteRequest) respond = (_) => sampleQuote();
  PricingFailure? nextFailure;

  @override
  Future<Quote> quote(QuoteRequest request) async {
    requests.add(request);
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
    return respond(request);
  }
}

class FakeFoundationRepository implements FoundationRepository {
  new({List<Foundation>? list})
    : list =
          list ??
          [
            const Foundation(
              id: 'f1',
              name: 'Fundación Demo Patitas',
              description: 'Rescate (ficticia).',
              active: true,
              isDefault: true,
            ),
            const Foundation(
              id: 'f2',
              name: 'Fundación Demo Bigotes',
              active: true,
              isDefault: false,
            ),
          ];

  List<Foundation> list;
  String? myChoice;
  Foundation? member;
  List<FoundationMonth> months = [];
  final created = <FoundationDraft>[];
  final choices = <String?>[];
  PricingFailure? nextFailure;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  Foundation _copy(Foundation f, {bool? active, bool? isDefault}) => Foundation(
    id: f.id,
    name: f.name,
    description: f.description,
    website: f.website,
    active: active ?? f.active,
    isDefault: isDefault ?? f.isDefault,
  );

  @override
  Future<List<Foundation>> foundations() async => List.of(list);

  @override
  Future<String?> myFoundationId() async => myChoice;

  @override
  Future<void> setMyFoundation(String? foundationId) async {
    _maybeFail();
    choices.add(foundationId);
    myChoice = foundationId;
  }

  @override
  Future<Foundation?> memberFoundation() async => member;

  @override
  Future<List<FoundationMonth>> summary({int months = 12}) async {
    _maybeFail();
    return this.months;
  }

  @override
  Future<void> create(FoundationDraft draft) async {
    _maybeFail();
    created.add(draft);
    list = [
      ...list,
      Foundation(
        id: 'f${list.length + 1}',
        name: draft.name.trim(),
        active: true,
        isDefault: false,
      ),
    ];
  }

  @override
  Future<void> update(String id, FoundationDraft draft) async {
    _maybeFail();
  }

  @override
  Future<void> setActive(String id, {required bool active}) async {
    _maybeFail();
    list = [
      for (final f in list)
        if (f.id == id) _copy(f, active: active) else f,
    ];
  }

  @override
  Future<void> setDefault(String id) async {
    _maybeFail();
    list = [for (final f in list) _copy(f, isDefault: f.id == id)];
  }
}
