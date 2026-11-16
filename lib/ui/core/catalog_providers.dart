import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';

final regionsProvider = FutureProvider<List<Region>>(
  (ref) => ref.watch(catalogRepositoryProvider).regions(),
);

final FutureProviderFamily<List<Commune>, int> communesProvider =
    FutureProvider.family<List<Commune>, int>(
      (ref, regionId) =>
          ref.watch(catalogRepositoryProvider).communes(regionId),
    );
