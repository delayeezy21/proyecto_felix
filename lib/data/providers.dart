import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
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
