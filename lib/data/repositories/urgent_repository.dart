import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// No se pudo aceptar la oferta: ya la tomó otro vet, venció o se cerró.
class OfferFailure extends VisitFailure {
  new(this.kind) : super(kind.message);

  final OfferFailureKind kind;
}

/// Urgencias (fase 8, docs/arquitectura.md §6). El despacho, los precios y la
/// privacidad los decide el servidor; aquí solo se llaman las RPC. Cancelar
/// usa `VisitRepository.transition` (igual que las agendadas).
abstract interface class UrgentRepository {
  /// Dueño: crea la urgencia (estado `searching`).
  Future<Visit> request({
    required String petId,
    required String addressId,
    int? specialtyId,
    String? foundationId,
    int extraDonation = 0,
    String? notes,
  });

  /// Dueño: avance de la búsqueda.
  Future<UrgentSearchStatus> searchStatus(String visitId);

  /// Vet: disponibilidad (cada 30 s en línea; [at] requerido si [online]).
  Future<void> setPresence({required bool online, GeoPoint? at});

  /// Vet: ofertas vigentes (sin dirección).
  Future<List<UrgentOffer>> myOffers();

  /// Vet: acepta. Devuelve la visita con la dirección exacta. Lanza
  /// [OfferFailure] si llegó tarde.
  Future<Visit> accept(String offerId);

  Future<void> reject(String offerId);
}

Future<T> _guard<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on PostgrestException catch (e) {
    if (OfferFailureKind.parse(e.hint) case final kind?) {
      throw OfferFailure(kind);
    }
    throw VisitFailure(switch (e.code) {
      // Las validaciones del servidor responden en español.
      '22023' => e.message,
      '42501' when e.message.startsWith('Solo') => e.message,
      '42501' when e.message.startsWith('Tu cuenta') => e.message,
      '42501' => 'No tienes permiso para esta acción.',
      _ => 'No se pudo completar la acción. Inténtalo de nuevo.',
    });
  }
}

class SupabaseUrgentRepository implements UrgentRepository {
  new(this._client);

  final SupabaseClient _client;

  @override
  Future<Visit> request({
    required String petId,
    required String addressId,
    int? specialtyId,
    String? foundationId,
    int extraDonation = 0,
    String? notes,
  }) => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'request_urgent_visit',
      params: {
        'p_pet_id': petId,
        'p_address_id': addressId,
        'p_specialty_id': specialtyId,
        'p_foundation_id': foundationId,
        'p_extra_donation': extraDonation,
        'p_notes': (notes ?? '').trim().isEmpty ? null : notes!.trim(),
      },
    );
    return Visit.fromJson(json);
  });

  @override
  Future<UrgentSearchStatus> searchStatus(String visitId) => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>?>(
      'urgent_search_status',
      params: {'p_visit_id': visitId},
    );
    if (json == null) throw const VisitFailure('No encontramos esta urgencia.');
    return UrgentSearchStatus.fromJson(json);
  });

  @override
  Future<void> setPresence({required bool online, GeoPoint? at}) => _guard(
    () => _client.rpc<void>(
      'set_vet_presence',
      params: {
        'p_online': online,
        'p_lat': online ? at?.lat : null,
        'p_lng': online ? at?.lng : null,
      },
    ),
  );

  @override
  Future<List<UrgentOffer>> myOffers() => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>('my_offers');
    return [
      for (final r in rows)
        UrgentOffer.fromJson((r as Map).cast<String, dynamic>()),
    ];
  });

  @override
  Future<Visit> accept(String offerId) => _guard(() async {
    final json = await _client.rpc<Map<String, dynamic>>(
      'accept_offer',
      params: {'p_offer_id': offerId},
    );
    return Visit.fromJson(json);
  });

  @override
  Future<void> reject(String offerId) => _guard(
    () => _client.rpc<void>('reject_offer', params: {'p_offer_id': offerId}),
  );
}
