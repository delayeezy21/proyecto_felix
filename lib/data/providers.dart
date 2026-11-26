import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/data/repositories/clinical_repository.dart';
import 'package:proyecto_felix/data/repositories/owner_repositories.dart';
import 'package:proyecto_felix/data/repositories/pricing_repository.dart';
import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/data/repositories/rating_repository.dart';
import 'package:proyecto_felix/data/repositories/subscription_repository.dart';
import 'package:proyecto_felix/data/repositories/urgent_repository.dart';
import 'package:proyecto_felix/data/repositories/vet_repository.dart';
import 'package:proyecto_felix/data/repositories/visit_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/data/services/live_location_service.dart';
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
  final blocked = ref.watch(accountBlockedSignalProvider);
  return auth.watchUserId().distinct().asyncMap((uid) async {
    if (uid == null) {
      blocked.clear();
      return const SignedOut();
    }
    try {
      return SignedIn(await profiles.fetchAccount());
    } on AccountBlockedException {
      // Inició sesión durante la gracia de un borrado (arquitectura §8.2).
      blocked.report();
      return const SignedIn(null, blocked: true);
    }
  });
});

final privacyRepositoryProvider = Provider<PrivacyRepository>(
  (ref) => SupabasePrivacyRepository(ref.watch(supabaseClientProvider)),
);

final visitRepositoryProvider = Provider<VisitRepository>(
  (ref) => SupabaseVisitRepository(ref.watch(supabaseClientProvider)),
);

final clinicalRepositoryProvider = Provider<ClinicalRepository>(
  (ref) => SupabaseClinicalRepository(ref.watch(supabaseClientProvider)),
);

final vetAgendaRepositoryProvider = Provider<VetAgendaRepository>(
  (ref) => SupabaseVetAgendaRepository(ref.watch(supabaseClientProvider)),
);

final urgentRepositoryProvider = Provider<UrgentRepository>(
  (ref) => SupabaseUrgentRepository(ref.watch(supabaseClientProvider)),
);

final ratingRepositoryProvider = Provider<RatingRepository>(
  (ref) => SupabaseRatingRepository(ref.watch(supabaseClientProvider)),
);

final subscriptionRepositoryProvider = Provider<SubscriptionRepository>(
  (ref) => SupabaseSubscriptionRepository(ref.watch(supabaseClientProvider)),
);

final liveLocationServiceProvider = Provider<LiveLocationService>(
  (ref) => SupabaseLiveLocationService(ref.watch(supabaseClientProvider)),
);
