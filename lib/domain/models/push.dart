import 'package:flutter/foundation.dart' show immutable;
import 'package:proyecto_felix/domain/models/visit.dart';

/// Tipo de aviso. El servidor manda `offer_new`, `offer_taken`,
/// `offer_cancelled` o `visit_<estado>`.
sealed class PushEvent {
  const new();

  static PushEvent? parse(String wire) => switch (wire) {
    'offer_new' => const OfferNew(),
    'offer_taken' => const OfferTaken(),
    'offer_cancelled' => const OfferCancelled(),
    _ when wire.startsWith('visit_') => _visit(wire.substring(6)),
    _ => null,
  };

  static PushEvent? _visit(String status) {
    for (final s in VisitStatus.values) {
      if (s.wire == status) return VisitChanged(s);
    }
    return null;
  }

  String get wire;
}

class OfferNew extends PushEvent {
  const new();

  @override
  String get wire => 'offer_new';
}

class OfferTaken extends PushEvent {
  const new();

  @override
  String get wire => 'offer_taken';
}

class OfferCancelled extends PushEvent {
  const new();

  @override
  String get wire => 'offer_cancelled';
}

class VisitChanged extends PushEvent {
  const new(this.status);

  final VisitStatus status;

  @override
  String get wire => 'visit_${status.wire}';
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Payload de un push (FCM `data`). Lleva **solo** `visit_id` y `event`: sin
/// nombre de mascota, dirección ni datos clínicos (FCM pasa por Google). El
/// texto lo arma la app y el detalle se trae por la API.
@immutable
class PushPayload {
  const new({required this.visitId, required this.event});

  /// Lee `data`. Devuelve null si falta alguno de los dos campos o no es
  /// válido. Cualquier otro campo se descarta: la app no lo usa ni lo guarda.
  static PushPayload? tryParse(Map<String, dynamic> data) {
    final id = data['visit_id'];
    final event = data['event'];
    if (id is! String || !_uuid.hasMatch(id) || event is! String) return null;
    final parsed = PushEvent.parse(event);
    if (parsed == null) return null;
    return PushPayload(visitId: id, event: parsed);
  }

  /// Campos que se esperan del servidor (ni uno más).
  static const fields = {'visit_id', 'event'};

  final String visitId;
  final PushEvent event;

  Map<String, String> toData() => {'visit_id': visitId, 'event': event.wire};

  /// Texto del aviso, armado en el dispositivo (sin datos personales).
  ({String title, String body}) text() => switch (event) {
    OfferNew() => (
      title: 'Nueva urgencia cerca',
      body: 'Tienes 60 segundos para aceptarla.',
    ),
    OfferTaken() => (
      title: 'Urgencia tomada',
      body: 'Otro veterinario ya tomó esta urgencia.',
    ),
    OfferCancelled() => (
      title: 'Urgencia cancelada',
      body: 'La solicitud ya no está disponible.',
    ),
    VisitChanged(:final status) => (
      title: 'Tu visita cambió',
      body: status.label,
    ),
  };
}
