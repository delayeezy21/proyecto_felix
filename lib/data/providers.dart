import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/data/repositories/owner_repositories.dart';
import 'package:proyecto_felix/data/repositories/pricing_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/data/repositories/vet_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Cliente de Supabase (solo existe si `.env` está configurado).
final supabaseClientProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => SupabaseAuthRepository(ref.watch(supabaseClientProvider).auth),
);

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => SupabaseProfileRepository(ref.watch(supabaseClientProvider)),
);

final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => SupabaseCatalogRepository(ref.watch(supabaseClientProvider)),
);

final vetRepositoryProvider = Provider<VetRepository>(
  (ref) => SupabaseVetRepository(ref.watch(supabaseClientProvider)),
);

final petRepositoryProvider = Provider<PetRepository>(
  (ref) => SupabasePetRepository(ref.watch(supabaseClientProvider)),
);

final addressRepositoryProvider = Provider<AddressRepository>(
  (ref) => SupabaseAddressRepository(ref.watch(supabaseClientProvider)),
);

final quoteRepositoryProvider = Provider<QuoteRepository>(
  (ref) => SupabaseQuoteRepository(ref.watch(supabaseClientProvider)),
);

final foundationRepositoryProvider = Provider<FoundationRepository>(
  (ref) => SupabaseFoundationRepository(ref.watch(supabaseClientProvider)),
);

/// Sesión actual: autenticación + cuenta (rol y perfil).
///
/// Tras completar el registro se hace `ref.invalidate(sessionProvider)`.
final sessionProvider = StreamProvider<SessionSnapshot>((ref) {
  final auth = ref.watch(authRepositoryProvider);
  final profiles = ref.watch(profileRepositoryProvider);
  return auth.watchUserId().distinct().asyncMap(
    (uid) async => uid == null
        ? const SignedOut()
        : SignedIn(await profiles.fetchAccount()),
  );
});
