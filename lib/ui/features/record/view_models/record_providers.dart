import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';

/// Clave de la ficha: mascota y, para el vet, la visita desde la que entra.
typedef RecordKey = ({String petId, String? visitId});

/// Ficha completa. Cada carga del vet queda registrada en el servidor: no se
/// refresca sola, solo al entrar o cuando el usuario lo pide.
final FutureProviderFamily<PetRecord, RecordKey> petRecordProvider =
    FutureProvider.autoDispose.family<PetRecord, RecordKey>(
      (ref, key) => ref
          .watch(clinicalRepositoryProvider)
          .record(key.petId, visitId: key.visitId),
    );

/// "Quién vio mi ficha" (solo el dueño).
final FutureProviderFamily<List<AccessLogItem>, String> accessLogProvider =
    FutureProvider.autoDispose.family<List<AccessLogItem>, String>(
      (ref, petId) => ref.watch(clinicalRepositoryProvider).accessLog(petId),
    );
