import 'package:flutter/foundation.dart' show immutable;

DateTime? _date(Object? v) => v is String ? DateTime.parse(v).toLocal() : null;

/// Fila del listado de clientes del admin (`admin_list_owners`). Una cuenta
/// en proceso de borrado llega sin datos personales ([blocked]).
@immutable
class AdminClient {
  const new({
    required this.userId,
    required this.displayName,
    required this.createdAt,
    required this.visitsTotal,
    required this.visitsCompleted,
    required this.blocked,
    this.email,
    this.phone,
    this.communeName,
    this.lastVisitAt,
  });

  factory fromJson(Map<String, dynamic> j) => AdminClient(
    userId: j['user_id'] as String,
    displayName: j['display_name'] as String? ?? 'Cliente',
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    communeName: j['commune_name'] as String?,
    createdAt: _date(j['created_at']) ?? DateTime(2000),
    visitsTotal: (j['visits_total'] as num?)?.toInt() ?? 0,
    visitsCompleted: (j['visits_completed'] as num?)?.toInt() ?? 0,
    lastVisitAt: _date(j['last_visit_at']),
    blocked: j['blocked'] as bool? ?? false,
  );

  final String userId;
  final String displayName;
  final String? email;
  final String? phone;
  final String? communeName;
  final DateTime createdAt;
  final int visitsTotal;
  final int visitsCompleted;
  final DateTime? lastVisitAt;
  final bool blocked;
}

/// Detalle de un cliente (`admin_owner_detail`): contacto y agregados. Sin
/// mascotas, direcciones, plan ni visitas individuales (minimización).
@immutable
class AdminClientDetail {
  const new({
    required this.userId,
    required this.displayName,
    required this.createdAt,
    required this.visitsByStatus,
    required this.urgentVisits,
    required this.paidTotal,
    required this.cancelFees,
    required this.donationsTotal,
    required this.ratingCount,
    this.email,
    this.phone,
    this.communeName,
    this.lastSignInAt,
    this.foundationName,
    this.lastVisitAt,
    this.ratingAvg,
  });

  factory fromJson(Map<String, dynamic> j) => AdminClientDetail(
    userId: j['user_id'] as String,
    displayName: j['display_name'] as String? ?? 'Cliente',
    email: j['email'] as String?,
    phone: j['phone'] as String?,
    communeName: j['commune_name'] as String?,
    createdAt: _date(j['created_at']) ?? DateTime(2000),
    lastSignInAt: _date(j['last_sign_in_at']),
    foundationName: j['foundation_name'] as String?,
    visitsByStatus: {
      for (final e in ((j['visits_by_status'] as Map?) ?? const {}).entries)
        e.key as String: (e.value as num).toInt(),
    },
    urgentVisits: (j['urgent_visits'] as num?)?.toInt() ?? 0,
    lastVisitAt: _date(j['last_visit_at']),
    paidTotal: (j['paid_total'] as num?)?.toInt() ?? 0,
    cancelFees: (j['cancel_fees'] as num?)?.toInt() ?? 0,
    donationsTotal: (j['donations_total'] as num?)?.toInt() ?? 0,
    ratingCount: (j['rating_count'] as num?)?.toInt() ?? 0,
    ratingAvg: (j['rating_avg'] as num?)?.toDouble(),
  );

  final String userId;
  final String displayName;
  final String? email;
  final String? phone;
  final String? communeName;
  final DateTime createdAt;
  final DateTime? lastSignInAt;
  final String? foundationName;
  final Map<String, int> visitsByStatus;
  final int urgentVisits;
  final DateTime? lastVisitAt;
  final int paidTotal;
  final int cancelFees;
  final int donationsTotal;
  final int ratingCount;
  final double? ratingAvg;

  int get visitsTotal => visitsByStatus.values.fold(0, (a, b) => a + b);
}
