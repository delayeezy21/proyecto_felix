import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';

/// Versiones legales vigentes que se muestran y aceptan en el registro.
final legalVersionsProvider = FutureProvider<LegalVersions>(
  (ref) => ref.watch(profileRepositoryProvider).fetchLegalVersions(),
);

/// Completa el registro (rol + perfil + términos + aviso de privacidad).
class OnboardingController extends AsyncNotifier<void> {
  @override
  void build() {}

  Future<bool> submit({
    required AppRole role,
    required String displayName,
    required String? phone,
    required LegalVersions legal,
    required bool marketingConsent,
    int? communeId,
  }) async {
    state = const AsyncLoading();
    final next = await AsyncValue.guard(
      () => ref
          .read(profileRepositoryProvider)
          .completeRegistration(
            role: role,
            displayName: displayName,
            phone: phone,
            legal: legal,
            marketingConsent: marketingConsent,
            communeId: communeId,
          ),
    );
    if (!ref.mounted) return false;
    state = next;
    if (next.hasError) return false;
    // La sesión vuelve a leer la cuenta y el router lleva al inicio del rol.
    ref.invalidate(sessionProvider);
    return true;
  }
}

final onboardingControllerProvider =
    AsyncNotifierProvider<OnboardingController, void>(OnboardingController.new);

String onboardingErrorMessage(Object error) => switch (error) {
  ProfileFailure(:final message) => message,
  _ => 'No se pudo completar el registro. Inténtalo de nuevo.',
};
