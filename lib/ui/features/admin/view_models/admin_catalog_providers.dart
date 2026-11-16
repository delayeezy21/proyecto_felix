import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';

final FutureProviderFamily<List<CatalogItem>, CatalogKind> adminItemsProvider =
    FutureProvider.family<List<CatalogItem>, CatalogKind>(
      (ref, kind) => ref.watch(catalogRepositoryProvider).items(kind),
    );

final adminTariffsProvider = FutureProvider<List<Tariff>>(
  (ref) => ref.watch(catalogRepositoryProvider).tariffs(),
);

final adminPricingProvider = FutureProvider<PricingConfig>(
  (ref) => ref.watch(catalogRepositoryProvider).currentPricing(),
);

final adminClinicsProvider = FutureProvider<List<EmergencyClinic>>(
  (ref) => ref.watch(catalogRepositoryProvider).clinics(),
);

/// Mensaje legible de un error de catálogo.
String catalogErrorMessage(Object error) => switch (error) {
  CatalogFailure(:final message) => message,
  _ => 'No se pudo completar la acción. Inténtalo de nuevo.',
};
