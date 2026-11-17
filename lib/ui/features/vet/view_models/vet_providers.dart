import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

final vetProfileProvider = FutureProvider<VetProfile>(
  (ref) => ref.watch(vetRepositoryProvider).myProfile(),
);

final vetSpeciesProvider = FutureProvider<Set<int>>(
  (ref) => ref.watch(vetRepositoryProvider).mySpeciesIds(),
);

final vetSpecialtiesProvider = FutureProvider<Set<int>>(
  (ref) => ref.watch(vetRepositoryProvider).mySpecialtyIds(),
);

final vetAvailabilityProvider = FutureProvider<List<AvailabilityBlock>>(
  (ref) => ref.watch(vetRepositoryProvider).myAvailability(),
);

final vetDocumentsProvider = FutureProvider<List<VetDocument>>(
  (ref) => ref.watch(vetRepositoryProvider).myDocuments(),
);

/// Requisitos pendientes para enviar la solicitud (la BD vuelve a validarlos).
List<String> missingRequirements({
  required VetProfile profile,
  required Set<int> species,
  required Set<int> specialties,
  required List<VetDocument> documents,
}) {
  bool hasDoc(VetDocumentKind k) =>
      documents.any((d) => d.kind == k && !d.isPurged);
  return [
    if ((profile.university ?? '').isEmpty) 'Universidad',
    if (profile.graduationYear == null) 'Año de titulación',
    if (species.isEmpty) 'Al menos una especie',
    if (specialties.isEmpty) 'Al menos una especialidad',
    if (!hasDoc(VetDocumentKind.degreeCertificate)) 'Certificado de título',
    if (!hasDoc(VetDocumentKind.idCardFront)) 'Cédula de identidad (anverso)',
    if (profile.declarationAcceptedAt == null) 'Declaración jurada',
  ];
}

const declarationText =
    'Declaro bajo juramento que poseo el título de Médico Veterinario otorgado '
    'por una universidad reconocida por el Estado de Chile (o revalidado en '
    'Chile), que los documentos que subo son auténticos y que la información '
    'entregada es verídica. Entiendo que entregar información falsa causa el '
    'rechazo o la suspensión de mi cuenta y puede tener consecuencias legales.';

/// ¿Hay cambios en los datos profesionales aún sin guardar? Mientras sea true
/// no se envía la solicitud, para no perder el último cambio (QA-13).
class VetDataDirty extends Notifier<bool> {
  @override
  bool build() => false;

  bool get dirty => state;
  set dirty(bool value) => state = value;
}

// autoDispose: se reinicia al salir de la pantalla o cambiar de cuenta (QA-15).
final NotifierProvider<VetDataDirty, bool> vetDataDirtyProvider =
    NotifierProvider.autoDispose<VetDataDirty, bool>(VetDataDirty.new);
