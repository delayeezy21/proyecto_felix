import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/domain/models/rating.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error legible de calificaciones y alertas.
class RatingFailure implements Exception {
  const new(this.message, {this.alreadyRated = false});

  final String message;

  /// 23505: ya había calificado esta visita.
  final bool alreadyRated;

  @override
  String toString() => 'RatingFailure: $message';
}

/// Calificaciones (fase 9). Todas las reglas (quién, plazo, publicación,
/// moderación) las aplica el servidor; aquí solo se llaman las RPC.
abstract interface class RatingRepository {
  Future<RatingStatus> status(String visitId);

  /// Califica la visita (1 a 5 estrellas, comentario opcional ≤ 500).
  Future<RatingStatus> rate(
    String visitId, {
    required int stars,
    String? comment,
  });

  /// Mis calificaciones recibidas y publicadas (sin quién las hizo).
  Future<List<ReceivedRating>> received({int limit = 50});

  Future<RatingSummary> mySummary();

  /// Promedio público de un vet aprobado (null si no está disponible).
  Future<VetRatingSummary?> vetSummary(String vetId);

  // Admin.
  Future<List<AdminRating>> adminList({int limit = 100});

  Future<bool> adminSetHidden(String ratingId, {required bool hidden});

  Future<List<CancelAlert>> adminCancelAlerts({bool includeReviewed = false});

  Future<void> adminReviewCancelAlert(String alertId);
}

/// Traduce un error de PostgREST de las RPC de calificaciones.
Exception mapRatingError(PostgrestException e) {
  // La cuenta bloqueada es la de la otra parte: no es la mía.
  if (e.hint == 'counterpart_blocked' ||
      e.message.startsWith('La otra cuenta tiene una solicitud')) {
    return const RatingFailure(
      'Esta visita ya no se puede calificar: la otra cuenta está en proceso '
      'de borrado.',
    );
  }
  if (isAccountBlocked(e)) return const AccountBlockedException();
  return switch (e.code) {
    '23505' => const RatingFailure(
      'Ya calificaste esta visita.',
      alreadyRated: true,
    ),
    // Validaciones del servidor (no completada, plazo vencido, datos
    // inválidos) responden en español.
    '22023' => RatingFailure(e.message),
    '42501' => const RatingFailure(
      'No puedes calificar ni ver esta calificación.',
    ),
    '28000' => const RatingFailure('Tu sesión expiró.'),
    _ => const RatingFailure(
      'No se pudo completar la acción. Inténtalo de nuevo.',
    ),
  };
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw mapRatingError(e);
  }
}

Map<String, dynamic> _map(Object? v) => (v! as Map).cast<String, dynamic>();

class SupabaseRatingRepository implements RatingRepository {
  new(this._client);

  final SupabaseClient _client;

  Future<List<T>> _rows<T>(
    String fn,
    Map<String, dynamic> params,
    T Function(Map<String, dynamic>) parse,
  ) => _guard(() async {
    final r = await _client.rpc<List<dynamic>>(fn, params: params);
    return [for (final e in r) parse(_map(e))];
  });

  @override
  Future<RatingStatus> status(String visitId) => _guard(() async {
    final r = await _client.rpc<Object?>(
      'visit_rating_status',
      params: {'p_visit_id': visitId},
    );
    return RatingStatus.fromJson(_map(r));
  });

  @override
  Future<RatingStatus> rate(
    String visitId, {
    required int stars,
    String? comment,
  }) => _guard(() async {
    final text = comment?.trim();
    final r = await _client.rpc<Object?>(
      'rate_visit',
      params: {
        'p_visit_id': visitId,
        'p_stars': stars,
        'p_comment': (text == null || text.isEmpty) ? null : text,
      },
    );
    return RatingStatus.fromJson(_map(r));
  });

  @override
  Future<List<ReceivedRating>> received({int limit = 50}) =>
      _rows('my_ratings_received', {'p_limit': limit}, ReceivedRating.fromJson);

  @override
  Future<RatingSummary> mySummary() => _guard(
    () async => RatingSummary.fromJson(
      _map(await _client.rpc<Object?>('my_rating_summary')),
    ),
  );

  @override
  Future<VetRatingSummary?> vetSummary(String vetId) => _guard(() async {
    final r = await _client.rpc<Object?>(
      'vet_rating_summary',
      params: {'p_vet_id': vetId},
    );
    return r == null ? null : VetRatingSummary.fromJson(_map(r));
  });

  @override
  Future<List<AdminRating>> adminList({int limit = 100}) =>
      _rows('admin_list_ratings', {'p_limit': limit}, AdminRating.fromJson);

  @override
  Future<bool> adminSetHidden(String ratingId, {required bool hidden}) =>
      _guard(() async {
        final r = await _client.rpc<Object?>(
          'admin_set_rating_hidden',
          params: {'p_rating_id': ratingId, 'p_hidden': hidden},
        );
        return _map(r)['hidden'] as bool? ?? hidden;
      });

  @override
  Future<List<CancelAlert>> adminCancelAlerts({bool includeReviewed = false}) =>
      _rows('admin_list_cancel_alerts', {
        'p_include_reviewed': includeReviewed,
      }, CancelAlert.fromJson);

  @override
  Future<void> adminReviewCancelAlert(String alertId) => _guard(() async {
    await _client.rpc<Object?>(
      'admin_review_cancel_alert',
      params: {'p_alert_id': alertId},
    );
  });
}
