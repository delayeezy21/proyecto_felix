import 'package:proyecto_felix/data/repositories/rating_repository.dart';
import 'package:proyecto_felix/domain/models/rating.dart';

/// Estado de calificación de ejemplo (visita completada, plazo vigente).
RatingStatus ratingStatus({
  String visitId = 'vis1',
  String role = 'owner',
  bool canRate = true,
  DateTime? rateUntil,
  MyRating? mine,
  TheirRating? theirs,
}) => RatingStatus(
  visitId: visitId,
  myRole: role,
  canRate: canRate,
  rateUntil: rateUntil ?? DateTime(2026, 11, 30, 12),
  mine: mine,
  theirs: theirs,
);

/// Calificaciones en memoria (fase 9). Simula el plazo, el "una vez" y la
/// publicación cuando ambos califican.
class FakeRatingRepository implements RatingRepository {
  final statuses = <String, RatingStatus>{};
  RatingSummary summary = const RatingSummary(
    ratingCount: 0,
    minRatings: 3,
    cancelCount30d: 0,
  );
  List<ReceivedRating> receivedList = [];
  final vetSummaries = <String, VetRatingSummary>{};
  List<AdminRating> adminRatings = [];
  List<CancelAlert> alerts = [];

  /// Calificación de la otra parte que se publica al calificar yo.
  final pendingTheirs = <String, TheirRating>{};

  final rateCalls = <(String, int, String?)>[];
  final hiddenCalls = <(String, bool)>[];
  final reviewCalls = <String>[];
  final alertQueries = <bool>[];
  int statusCalls = 0;

  /// Error de la próxima llamada (una vez).
  Exception? nextFailure;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  @override
  Future<RatingStatus> status(String visitId) async {
    statusCalls++;
    _maybeFail();
    return statuses[visitId] ?? ratingStatus(visitId: visitId);
  }

  @override
  Future<RatingStatus> rate(
    String visitId, {
    required int stars,
    String? comment,
  }) async {
    _maybeFail();
    final text = comment?.trim();
    rateCalls.add((visitId, stars, (text?.isEmpty ?? true) ? null : text));
    final s = statuses[visitId] ?? ratingStatus(visitId: visitId);
    if (s.mine != null) {
      throw const RatingFailure(
        'Ya calificaste esta visita.',
        alreadyRated: true,
      );
    }
    final next = RatingStatus(
      visitId: visitId,
      myRole: s.myRole,
      canRate: false,
      rateUntil: s.rateUntil,
      mine: MyRating(stars: stars, comment: text, publishesAt: s.rateUntil),
      theirs: pendingTheirs[visitId],
    );
    statuses[visitId] = next;
    return next;
  }

  @override
  Future<List<ReceivedRating>> received({int limit = 50}) async {
    _maybeFail();
    return List.of(receivedList);
  }

  @override
  Future<RatingSummary> mySummary() async {
    _maybeFail();
    return summary;
  }

  @override
  Future<VetRatingSummary?> vetSummary(String vetId) async =>
      vetSummaries[vetId];

  @override
  Future<List<AdminRating>> adminList({int limit = 100}) async {
    _maybeFail();
    return List.of(adminRatings);
  }

  @override
  Future<bool> adminSetHidden(String ratingId, {required bool hidden}) async {
    _maybeFail();
    hiddenCalls.add((ratingId, hidden));
    adminRatings = [
      for (final r in adminRatings)
        if (r.id == ratingId) r.copyWith(hidden: hidden) else r,
    ];
    return hidden;
  }

  @override
  Future<List<CancelAlert>> adminCancelAlerts({
    bool includeReviewed = false,
  }) async {
    _maybeFail();
    alertQueries.add(includeReviewed);
    return [
      for (final a in alerts)
        if (includeReviewed || !a.reviewed) a,
    ];
  }

  @override
  Future<void> adminReviewCancelAlert(String alertId) async {
    _maybeFail();
    reviewCalls.add(alertId);
    alerts = [
      for (final a in alerts)
        if (a.id == alertId)
          CancelAlert(
            id: a.id,
            vetId: a.vetId,
            vetName: a.vetName,
            cancelCount: a.cancelCount,
            cancelCount30d: a.cancelCount30d,
            lastCancelAt: a.lastCancelAt,
            reviewedAt: DateTime(2026, 11, 25, 10),
          )
        else
          a,
    ];
  }
}
