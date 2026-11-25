import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show AsyncNotifierProviderFamily, FutureProviderFamily;
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/rating_repository.dart';
import 'package:proyecto_felix/domain/models/rating.dart';

/// Estado de la calificación de una visita (`visit_rating_status`) y la
/// acción de calificar.
class VisitRatingController extends AsyncNotifier<RatingStatus> {
  new(this.visitId);

  final String visitId;

  RatingRepository get _repo => ref.read(ratingRepositoryProvider);

  @override
  Future<RatingStatus> build() =>
      ref.watch(ratingRepositoryProvider).status(visitId);

  /// Califica. Lanza el error para que la vista lo muestre; si ya había
  /// calificado (23505) recarga el estado para mostrar su calificación.
  Future<void> rate({required int stars, String? comment}) async {
    try {
      final next = await _repo.rate(visitId, stars: stars, comment: comment);
      if (ref.mounted) state = AsyncData(next);
      ref.invalidate(myRatingSummaryProvider);
    } on RatingFailure catch (e) {
      if (e.alreadyRated && ref.mounted) ref.invalidateSelf();
      rethrow;
    }
  }
}

final AsyncNotifierProviderFamily<VisitRatingController, RatingStatus, String>
visitRatingProvider = AsyncNotifierProvider.autoDispose
    .family<VisitRatingController, RatingStatus, String>(
      VisitRatingController.new,
    );

/// Mi promedio recibido y, si soy vet, mis cancelaciones en 30 días.
final FutureProvider<RatingSummary> myRatingSummaryProvider =
    FutureProvider.autoDispose(
      (ref) => ref.watch(ratingRepositoryProvider).mySummary(),
    );

/// Calificaciones recibidas y publicadas (sin autor).
final FutureProvider<List<ReceivedRating>> myRatingsReceivedProvider =
    FutureProvider.autoDispose(
      (ref) => ref.watch(ratingRepositoryProvider).received(),
    );

/// Promedio público de un vet (al elegir veterinario). Un fallo no debe
/// romper la reserva: la vista simplemente no muestra el promedio.
final FutureProviderFamily<VetRatingSummary?, String> vetRatingSummaryProvider =
    FutureProvider.autoDispose.family<VetRatingSummary?, String>(
      (ref, vetId) => ref.watch(ratingRepositoryProvider).vetSummary(vetId),
    );

/// Admin: calificaciones para moderar (también las no publicadas).
class AdminRatingsController extends AsyncNotifier<List<AdminRating>> {
  @override
  Future<List<AdminRating>> build() =>
      ref.watch(ratingRepositoryProvider).adminList();

  /// Oculta o muestra el comentario. Lanza el error para la vista.
  Future<void> setHidden(String ratingId, {required bool hidden}) async {
    final value = await ref
        .read(ratingRepositoryProvider)
        .adminSetHidden(ratingId, hidden: hidden);
    if (!ref.mounted) return;
    final list = state.value;
    if (list == null) return;
    state = AsyncData([
      for (final r in list)
        if (r.id == ratingId) r.copyWith(hidden: value) else r,
    ]);
  }
}

final AsyncNotifierProvider<AdminRatingsController, List<AdminRating>>
adminRatingsProvider = AsyncNotifierProvider.autoDispose(
  AdminRatingsController.new,
);

/// Admin: alertas de cancelación (solo abiertas, o también las revisadas).
class CancelAlertsController extends AsyncNotifier<List<CancelAlert>> {
  // El argumento de la familia es posicional.
  // ignore: avoid_positional_boolean_parameters
  new(this.includeReviewed);

  final bool includeReviewed;

  @override
  Future<List<CancelAlert>> build() => ref
      .watch(ratingRepositoryProvider)
      .adminCancelAlerts(includeReviewed: includeReviewed);

  /// Marca la alerta como revisada y recarga la lista.
  Future<void> review(String alertId) async {
    await ref.read(ratingRepositoryProvider).adminReviewCancelAlert(alertId);
    if (ref.mounted) ref.invalidate(cancelAlertsProvider);
  }
}

final AsyncNotifierProviderFamily<
  CancelAlertsController,
  List<CancelAlert>,
  bool
>
cancelAlertsProvider = AsyncNotifierProvider.autoDispose
    .family<CancelAlertsController, List<CancelAlert>, bool>(
      CancelAlertsController.new,
    );
