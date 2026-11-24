import 'package:flutter/foundation.dart' show immutable;
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';

/// Estados de la visita (docs/arquitectura.md §5). El cliente nunca cambia el
/// estado directo: pide la transición a `transition_visit`.
enum VisitStatus {
  searching('searching', 'Buscando veterinario'),
  pendingVet('pending_vet', 'Esperando confirmación'),
  accepted('accepted', 'Confirmada'),
  enRoute('en_route', 'Veterinario en camino'),
  arrived('arrived', 'Veterinario llegó'),
  inProgress('in_progress', 'En atención'),
  completed('completed', 'Completada'),
  rejected('rejected', 'Rechazada por el veterinario'),
  expired('expired', 'Expiró sin confirmación'),
  noVetFound('no_vet_found', 'Sin veterinario disponible'),
  cancelledOwner('cancelled_owner', 'Cancelada por el dueño'),
  cancelledVet('cancelled_vet', 'Cancelada por el veterinario');

  new(this.wire, this.label);

  final String wire;
  final String label;

  static VisitStatus parse(String? v) =>
      values.firstWhere((s) => s.wire == v, orElse: () => pendingVet);

  /// Ocupa la agenda del vet (mismo conjunto que la restricción de exclusión).
  bool get isOpen =>
      const {pendingVet, accepted, enRoute, arrived, inProgress}.contains(this);

  /// El vet asignado ve la dirección exacta solo en estos estados.
  bool get isAssignedActive =>
      const {accepted, enRoute, arrived, inProgress}.contains(this);

  bool get isClosed => !isOpen && this != searching;

  /// El dueño puede cancelar (el cargo lo calcula el servidor).
  bool get ownerCanCancel =>
      const {searching, pendingVet, accepted, enRoute}.contains(this);
}

/// Acción del vet: transición destino + texto del botón.
@immutable
class VetAction {
  const new(this.to, this.label, {this.destructive = false});

  final VisitStatus to;
  final String label;
  final bool destructive;
}

/// Acciones del vet según el estado (las valida de nuevo el servidor).
List<VetAction> vetActionsFor(VisitStatus status) => switch (status) {
  VisitStatus.pendingVet => const [
    VetAction(VisitStatus.accepted, 'Confirmar'),
    VetAction(VisitStatus.rejected, 'Rechazar', destructive: true),
  ],
  VisitStatus.accepted => const [
    VetAction(VisitStatus.enRoute, 'Voy en camino'),
    VetAction(VisitStatus.cancelledVet, 'Cancelar visita', destructive: true),
  ],
  VisitStatus.enRoute => const [
    VetAction(VisitStatus.arrived, 'Llegué'),
    VetAction(VisitStatus.cancelledVet, 'Cancelar visita', destructive: true),
  ],
  VisitStatus.arrived => const [
    VetAction(VisitStatus.inProgress, 'Iniciar atención'),
    VetAction(VisitStatus.cancelledVet, 'Cancelar visita', destructive: true),
  ],
  VisitStatus.inProgress => const [
    VetAction(VisitStatus.completed, 'Completar visita'),
  ],
  _ => const [],
};

/// Veterinario disponible para agendar (solo datos públicos).
@immutable
class AvailableVet {
  const new({
    required this.vetId,
    required this.displayName,
    required this.distanceKm,
    required this.slots,
    this.bio,
  });

  factory fromJson(Map<String, dynamic> j) => AvailableVet(
    vetId: j['vet_id'] as String,
    displayName: j['display_name'] as String,
    bio: j['bio'] as String?,
    distanceKm: (j['distance_km'] as num).toDouble(),
    slots: [
      for (final s in (j['slots'] as List? ?? const []))
        DateTime.parse(s as String).toLocal(),
    ],
  );

  final String vetId;
  final String displayName;
  final String? bio;
  final double distanceKm;
  final List<DateTime> slots;
}

/// Dirección exacta y contacto: solo llega al vet asignado con la visita
/// activa.
@immutable
class VisitExactAddress {
  const new({
    required this.streetText,
    required this.point,
    this.details,
    this.ownerName,
    this.ownerPhone,
  });

  factory fromJson(Map<String, dynamic> j) => VisitExactAddress(
    streetText: j['street_text'] as String,
    details: j['details'] as String?,
    point: GeoPoint((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
    ownerName: j['owner_name'] as String?,
    ownerPhone: j['owner_phone'] as String?,
  );

  final String streetText;
  final String? details;
  final GeoPoint point;
  final String? ownerName;
  final String? ownerPhone;
}

/// Visita vista por el dueño o por el vet (`my_visits`). Cada uno recibe
/// solo los campos que le corresponden.
@immutable
class Visit {
  const new({
    required this.id,
    required this.isOwnerView,
    required this.status,
    required this.mode,
    this.scheduledAt,
    this.confirmDeadline,
    this.petName,
    this.speciesName,
    this.specialtyName,
    this.communeName,
    this.notes,
    this.cancelReason,
    this.paid = false,
    this.vetName,
    this.addressLabel,
    this.addressText,
    this.quote,
    this.cancelFee = 0,
    this.cancelFeeNow,
    this.servicePrice,
    this.vetPayout,
    this.distanceKm,
    this.exact,
    this.petId,
    this.addressId,
    this.vetId,
    this.closedBySystem = false,
    this.recordAccess = false,
    this.recordWritable = false,
    this.recordUntil,
  });

  factory fromJson(Map<String, dynamic> j) {
    DateTime? date(String k) =>
        j[k] == null ? null : DateTime.parse(j[k] as String).toLocal();
    final quote = j['quote'];
    final exact = j['exact'];
    return Visit(
      id: j['id'] as String,
      isOwnerView: j['viewer'] == 'owner',
      status: VisitStatus.parse(j['status'] as String?),
      mode: VisitMode.parse(j['mode'] as String?),
      scheduledAt: date('scheduled_at'),
      confirmDeadline: date('confirm_deadline'),
      petName: j['pet_name'] as String?,
      speciesName: j['species_name'] as String?,
      specialtyName: j['specialty_name'] as String?,
      communeName: j['commune_name'] as String?,
      notes: j['notes'] as String?,
      cancelReason: j['cancel_reason'] as String?,
      paid: j['paid'] as bool? ?? false,
      vetName: j['vet_name'] as String?,
      addressLabel: j['address_label'] as String?,
      addressText: j['address_text'] as String?,
      quote: quote is Map<String, dynamic> ? Quote.fromJson(quote) : null,
      cancelFee: (j['cancel_fee'] as num?)?.toInt() ?? 0,
      cancelFeeNow: (j['cancel_fee_now'] as num?)?.toInt(),
      servicePrice: (j['service_price'] as num?)?.toInt(),
      vetPayout: (j['vet_payout'] as num?)?.toInt(),
      distanceKm: (j['distance_km'] as num?)?.toDouble(),
      exact: exact is Map<String, dynamic>
          ? VisitExactAddress.fromJson(exact)
          : null,
      petId: j['pet_id'] as String?,
      addressId: j['address_id'] as String?,
      vetId: j['vet_id'] as String?,
      closedBySystem: j['closed_by_system'] as bool? ?? false,
      recordAccess: j['record_access'] as bool? ?? false,
      recordWritable: j['record_writable'] as bool? ?? false,
      recordUntil: date('record_until'),
    );
  }

  final String id;
  final bool isOwnerView;
  final VisitStatus status;
  final VisitMode mode;
  final DateTime? scheduledAt;
  final DateTime? confirmDeadline;
  final String? petName;
  final String? speciesName;
  final String? specialtyName;
  final String? communeName;
  final String? notes;
  final String? cancelReason;
  final bool paid;

  // Vista del dueño.
  final String? vetName;
  final String? addressLabel;
  final String? addressText;

  /// Precio congelado al reservar.
  final Quote? quote;
  final int cancelFee;

  /// Cargo si cancela ahora (null = ya no se puede cancelar).
  final int? cancelFeeNow;

  // Vista del vet.
  final int? servicePrice;
  final int? vetPayout;
  final double? distanceKm;
  final VisitExactAddress? exact;

  final String? petId;

  /// Dirección de la visita (solo en la vista del dueño).
  final String? addressId;

  /// Vet asignado (solo en la vista del dueño; dato público).
  final String? vetId;

  /// La cerró el sistema (cron), no el vet ni el dueño (O-6).
  final bool closedBySystem;

  // Ficha clínica (vista del vet): acceso vigente por esta visita, si puede
  // escribir en ella y hasta cuándo (null = mientras la visita esté activa).
  final bool recordAccess;
  final bool recordWritable;
  final DateTime? recordUntil;

  bool get canPay => isOwnerView && status == VisitStatus.completed && !paid;

  bool get canCancel =>
      isOwnerView && status.ownerCanCancel && cancelFeeNow != null;
}

/// Resultado del pago simulado.
@immutable
class PaymentResult {
  const new({required this.paid, required this.total});

  final bool paid;
  final int total;
}

/// Fila del resumen del admin (solo agregados).
@immutable
class VisitStatusCount {
  const new({required this.mode, required this.status, required this.total});

  final VisitMode mode;
  final VisitStatus status;
  final int total;
}

/// Punto de partida del vet (origen de la distancia). Solo lo ve él.
@immutable
class VetBase {
  const new({required this.communeId, required this.point});

  final int communeId;
  final GeoPoint point;
}

/// Días libres del vet (rango de días completos, hora de Chile).
@immutable
class TimeOff {
  const new({required this.id, required this.from, required this.to});

  final String id;

  /// Primer día libre.
  final DateTime from;

  /// Último día libre (inclusive).
  final DateTime to;
}

const _weekdays = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
const _monthsShort = [
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sept',
  'oct',
  'nov',
  'dic',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "10:30".
String formatHour(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// "mar 18 nov".
String formatDay(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${d.day} ${_monthsShort[d.month - 1]}';

/// "mar 18 nov · 10:30".
String formatSlot(DateTime d) => '${formatDay(d)} · ${formatHour(d)}';

/// Fecha sin hora (para enviar `p_date`).
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// "8 km" / "7,5 km".
String formatKm(double km) =>
    '${km.toStringAsFixed(km % 1 == 0 ? 0 : 1).replaceAll('.', ',')} km';
