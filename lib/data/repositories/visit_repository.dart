import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error legible de visitas y agenda.
class VisitFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'VisitFailure: $message';
}

/// Visitas agendadas: disponibilidad, reserva, estados y pago simulado. Toda
/// regla (precio, solapes, quién cambia qué estado, privacidad) la aplica el
/// servidor; aquí solo se llaman las RPC.
abstract interface class VisitRepository {
  Future<List<AvailableVet>> availableVets({
    required String petId,
    required String addressId,
    required int specialtyId,
    required DateTime date,
  });

  /// Reserva con una cotización que debe coincidir con vet, mascota y
  /// dirección.
  Future<Visit> book({
    required String quoteId,
    required String vetId,
    required String petId,
    required String addressId,
    required DateTime scheduledAt,
    String? notes,
  });

  Future<List<Visit>> myVisits();

  /// Pide una transición. Devuelve el cargo aplicado (cancelación).
  Future<int> transition(String visitId, VisitStatus to, {String? reason});

  Future<PaymentResult> pay(String visitId, {bool simulateFailure = false});

  /// Resumen agregado para el admin (últimos [days] días).
  Future<List<VisitStatusCount>> adminSummary({int days = 30});
}

/// Agenda propia del vet: punto de partida y días libres.
abstract interface class VetAgendaRepository {
  Future<VetBase?> myBase();

  Future<void> saveBase(VetBase base);

  Future<List<TimeOff>> myTimeOff();

  Future<void> addTimeOff(DateTime from, DateTime to);

  Future<void> removeTimeOff(String id);
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    throw VisitFailure(switch (e.code) {
      // Las validaciones del servidor responden en español.
      '22023' => e.message,
      '42501' when e.message.startsWith('Esta acción') => e.message,
      '42501' => 'No tienes permiso para esta acción.',
      _ => 'No se pudo completar la acción. Inténtalo de nuevo.',
    });
  }
}

String _uid(SupabaseClient client) {
  final uid = client.auth.currentUser?.id;
  if (uid == null) throw const VisitFailure('Tu sesión expiró.');
  return uid;
}

class SupabaseVisitRepository implements VisitRepository {
  new(this._client);

  final SupabaseClient _client;

  @override
  Future<List<AvailableVet>> availableVets({
    required String petId,
    required String addressId,
    required int specialtyId,
    required DateTime date,
  }) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'available_vets',
      params: {
        'p_pet_id': petId,
        'p_address_id': addressId,
        'p_specialty_id': specialtyId,
        'p_date': isoDate(date),
      },
    );
    return [
      for (final r in rows)
        AvailableVet.fromJson((r as Map).cast<String, dynamic>()),
    ];
  });

  @override
  Future<Visit> book({
    required String quoteId,
    required String vetId,
    required String petId,
    required String addressId,
    required DateTime scheduledAt,
    String? notes,
  }) => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'book_visit',
      params: {
        'p_quote_id': quoteId,
        'p_vet_id': vetId,
        'p_pet_id': petId,
        'p_address_id': addressId,
        'p_scheduled_at': scheduledAt.toUtc().toIso8601String(),
        'p_notes': (notes ?? '').trim().isEmpty ? null : notes!.trim(),
      },
    );
    return Visit.fromJson(json);
  });

  @override
  Future<List<Visit>> myVisits() => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'my_visits',
      params: {'p_limit': 100},
    );
    return [
      for (final r in rows) Visit.fromJson((r as Map).cast<String, dynamic>()),
    ];
  });

  @override
  Future<int> transition(String visitId, VisitStatus to, {String? reason}) =>
      _guard(() async {
        final json = await _client.rpc<Map<String, dynamic>>(
          'transition_visit',
          params: {
            'p_visit_id': visitId,
            'p_to_status': to.wire,
            'p_reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
          },
        );
        return (json['cancel_fee'] as num?)?.toInt() ?? 0;
      });

  @override
  Future<PaymentResult> pay(String visitId, {bool simulateFailure = false}) =>
      _guard(() async {
        final json = await _client.rpc<Map<String, dynamic>>(
          'simulate_payment',
          params: {
            'p_visit_id': visitId,
            'p_simulate_failure': simulateFailure,
          },
        );
        return PaymentResult(
          paid: json['status'] == 'simulated_paid',
          total: (json['total'] as num).toInt(),
        );
      });

  @override
  Future<List<VisitStatusCount>> adminSummary({int days = 30}) =>
      _guard(() async {
        final rows = await _client.rpc<List<dynamic>>(
          'admin_visit_summary',
          params: {'p_days': days},
        );
        return [
          for (final r in rows.cast<Map<String, dynamic>>())
            VisitStatusCount(
              mode: VisitMode.parse(r['mode'] as String?),
              status: VisitStatus.parse(r['status'] as String?),
              total: (r['total'] as num).toInt(),
            ),
        ];
      });
}

class SupabaseVetAgendaRepository implements VetAgendaRepository {
  new(this._client);

  final SupabaseClient _client;

  @override
  Future<VetBase?> myBase() => _guard(() async {
    final row = await _client
        .from('vet_bases')
        .select('commune_id, lat, lng')
        .eq('vet_id', _uid(_client))
        .maybeSingle();
    if (row == null) return null;
    return VetBase(
      communeId: row['commune_id'] as int,
      point: GeoPoint(
        (row['lat'] as num).toDouble(),
        (row['lng'] as num).toDouble(),
      ),
    );
  });

  @override
  Future<void> saveBase(VetBase base) => _guard(() async {
    final uid = _uid(_client);
    final values = {
      'commune_id': base.communeId,
      'lat': base.point.lat,
      'lng': base.point.lng,
    };
    // Sin upsert: el vet no tiene UPDATE sobre vet_id (grants por columna).
    final updated = await _client
        .from('vet_bases')
        .update(values)
        .eq('vet_id', uid)
        .select('vet_id');
    if (updated.isEmpty) {
      await _client.from('vet_bases').insert({'vet_id': uid, ...values});
    }
  });

  @override
  Future<List<TimeOff>> myTimeOff() => _guard(() async {
    final rows = await _client
        .from('vet_time_off')
        .select('id, period')
        .eq('vet_id', _uid(_client))
        .order('period');
    return [
      for (final r in rows)
        ?parseTimeOff(r['id'] as String, r['period'] as String),
    ];
  });

  @override
  Future<void> addTimeOff(DateTime from, DateTime to) => _guard(
    () => _client.rpc<void>(
      'add_time_off',
      params: {'p_from': isoDate(from), 'p_to': isoDate(to)},
    ),
  );

  @override
  Future<void> removeTimeOff(String id) =>
      _guard(() => _client.from('vet_time_off').delete().eq('id', id));
}

/// `["2026-11-20 03:00:00+00","2026-11-21 03:00:00+00")` → días 20 a 20.
TimeOff? parseTimeOff(String id, String range) {
  final parts = range
      .replaceAll(RegExp(r'[\[\]()"]'), '')
      .split(',')
      .map((s) => s.trim())
      .toList();
  if (parts.length != 2) return null;
  final from = DateTime.tryParse(parts[0])?.toLocal();
  final until = DateTime.tryParse(parts[1])?.toLocal();
  if (from == null || until == null) return null;
  final last = until.subtract(const Duration(days: 1));
  return TimeOff(
    id: id,
    from: DateTime(from.year, from.month, from.day),
    to: DateTime(last.year, last.month, last.day),
  );
}
