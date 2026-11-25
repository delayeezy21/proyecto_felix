/// Calificaciones y cancelaciones del vet (fase 9, docs/arquitectura.md §5.1).
/// Las reglas (plazo de 7 días, publicación diferida, mínimo para el
/// promedio, alertas) las aplica el servidor; aquí solo se leen.
library;

/// Largo máximo del comentario (lo valida también el servidor).
const ratingCommentMax = 500;

DateTime? _date(Object? v) =>
    v == null ? null : DateTime.parse(v as String).toLocal();

double? _double(Object? v) => (v as num?)?.toDouble();

/// Calificación que hice en una visita.
class MyRating {
  const new({
    required this.stars,
    this.comment,
    this.hidden = false,
    this.createdAt,
    this.publishesAt,
  });

  factory fromJson(Map<String, dynamic> j) => MyRating(
    stars: (j['stars'] as num).toInt(),
    comment: j['comment'] as String?,
    hidden: j['hidden'] as bool? ?? false,
    createdAt: _date(j['created_at']),
    publishesAt: _date(j['publishes_at']),
  );

  final int stars;
  final String? comment;

  /// El admin ocultó el comentario (las estrellas siguen contando).
  final bool hidden;
  final DateTime? createdAt;

  /// Desde cuándo la ve la otra parte.
  final DateTime? publishesAt;
}

/// Calificación de la otra parte (solo llega ya publicada).
class TheirRating {
  const new({
    required this.stars,
    this.comment,
    this.commentHidden = false,
    this.publishedAt,
  });

  factory fromJson(Map<String, dynamic> j) => TheirRating(
    stars: (j['stars'] as num).toInt(),
    comment: j['comment'] as String?,
    commentHidden: j['comment_hidden'] as bool? ?? false,
    publishedAt: _date(j['published_at']),
  );

  final int stars;

  /// null si no dejó comentario o si el admin lo ocultó.
  final String? comment;
  final bool commentHidden;
  final DateTime? publishedAt;
}

/// `visit_rating_status` / `rate_visit`.
class RatingStatus {
  const new({
    required this.visitId,
    required this.myRole,
    required this.canRate,
    this.rateUntil,
    this.mine,
    this.theirs,
  });

  factory fromJson(Map<String, dynamic> j) {
    final mine = j['mine'];
    final theirs = j['theirs'];
    return RatingStatus(
      visitId: j['visit_id'] as String,
      myRole: j['my_role'] as String? ?? 'owner',
      canRate: j['can_rate'] as bool? ?? false,
      rateUntil: _date(j['rate_until']),
      mine: mine is Map
          ? MyRating.fromJson(mine.cast<String, dynamic>())
          : null,
      theirs: theirs is Map
          ? TheirRating.fromJson(theirs.cast<String, dynamic>())
          : null,
    );
  }

  final String visitId;

  /// `owner` o `vet`.
  final String myRole;
  final bool canRate;

  /// Fin del plazo (null si la visita no está completada).
  final DateTime? rateUntil;
  final MyRating? mine;
  final TheirRating? theirs;

  bool get isOwner => myRole == 'owner';

  /// Ya no se puede calificar porque venció el plazo (sin haber calificado).
  bool expiredAt(DateTime now) =>
      mine == null && rateUntil != null && !now.isBefore(rateUntil!);
}

/// Calificación recibida (sin quién la hizo).
class ReceivedRating {
  const new({
    required this.visitId,
    required this.raterRole,
    required this.stars,
    this.comment,
    this.commentHidden = false,
    this.publishedAt,
  });

  factory fromJson(Map<String, dynamic> j) => ReceivedRating(
    visitId: j['visit_id'] as String,
    raterRole: j['rater_role'] as String? ?? 'owner',
    stars: (j['stars'] as num).toInt(),
    comment: j['comment'] as String?,
    commentHidden: j['comment_hidden'] as bool? ?? false,
    publishedAt: _date(j['published_at']),
  );

  final String visitId;
  final String raterRole;
  final int stars;
  final String? comment;
  final bool commentHidden;
  final DateTime? publishedAt;
}

/// `my_rating_summary`: promedio recibido y, para el vet, sus cancelaciones.
class RatingSummary {
  const new({
    required this.ratingCount,
    required this.minRatings,
    this.ratingAvg,
    this.cancelCount30d,
  });

  factory fromJson(Map<String, dynamic> j) => RatingSummary(
    ratingAvg: _double(j['rating_avg']),
    ratingCount: (j['rating_count'] as num?)?.toInt() ?? 0,
    minRatings: (j['min_ratings'] as num?)?.toInt() ?? 3,
    cancelCount30d: (j['cancel_count_30d'] as num?)?.toInt(),
  );

  /// null con menos de [minRatings] calificaciones publicadas.
  final double? ratingAvg;
  final int ratingCount;
  final int minRatings;

  /// Solo para el vet.
  final int? cancelCount30d;

  bool get hasAverage => ratingAvg != null && ratingCount >= minRatings;
}

/// `vet_rating_summary`: promedio público de un vet aprobado.
class VetRatingSummary {
  const new({required this.vetId, required this.ratingCount, this.ratingAvg});

  factory fromJson(Map<String, dynamic> j) => VetRatingSummary(
    vetId: j['vet_id'] as String,
    ratingAvg: _double(j['rating_avg']),
    ratingCount: (j['rating_count'] as num?)?.toInt() ?? 0,
  );

  final String vetId;

  /// null si no tiene suficientes calificaciones.
  final double? ratingAvg;
  final int ratingCount;
}

/// Fila de `admin_list_ratings`.
class AdminRating {
  const new({
    required this.id,
    required this.visitId,
    required this.raterRole,
    required this.stars,
    required this.hidden,
    required this.published,
    this.comment,
    this.createdAt,
    this.publishesAt,
  });

  factory fromJson(Map<String, dynamic> j) => AdminRating(
    id: j['id'] as String,
    visitId: j['visit_id'] as String,
    raterRole: j['rater_role'] as String? ?? 'owner',
    stars: (j['stars'] as num).toInt(),
    comment: j['comment'] as String?,
    hidden: j['hidden'] as bool? ?? false,
    published: j['published'] as bool? ?? false,
    createdAt: _date(j['created_at']),
    publishesAt: _date(j['publishes_at']),
  );

  final String id;
  final String visitId;
  final String raterRole;
  final int stars;
  final String? comment;
  final bool hidden;
  final bool published;
  final DateTime? createdAt;
  final DateTime? publishesAt;

  AdminRating copyWith({required bool hidden}) => AdminRating(
    id: id,
    visitId: visitId,
    raterRole: raterRole,
    stars: stars,
    comment: comment,
    hidden: hidden,
    published: published,
    createdAt: createdAt,
    publishesAt: publishesAt,
  );
}

/// Fila de `admin_list_cancel_alerts`.
class CancelAlert {
  const new({
    required this.id,
    required this.vetId,
    required this.vetName,
    required this.cancelCount,
    required this.cancelCount30d,
    this.firstCancelAt,
    this.lastCancelAt,
    this.createdAt,
    this.reviewedAt,
  });

  factory fromJson(Map<String, dynamic> j) => CancelAlert(
    id: j['id'] as String,
    vetId: j['vet_id'] as String,
    vetName: j['vet_name'] as String? ?? 'Veterinario',
    cancelCount: (j['cancel_count'] as num?)?.toInt() ?? 0,
    cancelCount30d: (j['cancel_count_30d'] as num?)?.toInt() ?? 0,
    firstCancelAt: _date(j['first_cancel_at']),
    lastCancelAt: _date(j['last_cancel_at']),
    createdAt: _date(j['created_at']),
    reviewedAt: _date(j['reviewed_at']),
  );

  final String id;
  final String vetId;
  final String vetName;

  /// Cancelaciones al abrir o actualizar la alerta.
  final int cancelCount;

  /// Cancelaciones en los últimos 30 días, ahora.
  final int cancelCount30d;
  final DateTime? firstCancelAt;
  final DateTime? lastCancelAt;
  final DateTime? createdAt;
  final DateTime? reviewedAt;

  bool get reviewed => reviewedAt != null;
}

/// "4,3" (coma decimal, una cifra).
String formatRating(double avg) => avg.toStringAsFixed(1).replaceAll('.', ',');

/// Etiqueta accesible: "3 de 5 estrellas".
String starsLabel(int stars) => '$stars de 5 estrellas';
