import 'package:proyecto_felix/domain/models/account.dart';

abstract final class AppRoutes {
  static const splash = '/splash';
  static const sessionError = '/session-error';
  static const login = '/login';
  static const signUp = '/signup';
  static const forgotPassword = '/forgot-password';
  static const resetPassword = '/reset-password';
  static const about = '/about';
  static const onboarding = '/onboarding';
  static const owner = '/owner';
  static const ownerPetNew = '/owner/pets/new';
  static const ownerAddressNew = '/owner/addresses/new';
  static const ownerProfile = '/owner/profile';
  static String ownerPet(String id) => '/owner/pets/$id';
  static String ownerAddress(String id) => '/owner/addresses/$id';
  static const vet = '/vet';
  static const vetPending = '/vet/pending';
  static const admin = '/admin';
  static const foundation = '/foundation';

  static const Set<String> _public = {login, signUp, forgotPassword};

  /// Pantalla de inicio según el rol (y el estado de aprobación del vet).
  static String homeFor(Account account) => switch (account.role) {
    AppRole.owner => owner,
    AppRole.vet => account.vetStatus == VetStatus.approved ? vet : vetPending,
    AppRole.admin => admin,
    AppRole.foundation => foundation,
  };

  /// Decide la redirección. Devuelve null si el usuario puede quedarse.
  ///
  /// Función pura: la usa go_router y se prueba con tests unitarios.
  ///
  /// [recoveringPassword]: el usuario volvió del enlace de "Olvidé mi
  /// contraseña" y debe fijar una nueva antes de seguir.
  static String? redirect(
    SessionSnapshot session,
    String location, {
    bool recoveringPassword = false,
  }) {
    if (recoveringPassword && session is SignedIn) {
      return location == resetPassword ? null : resetPassword;
    }
    // "Acerca de / licencias" se abre con o sin sesión (atribución CC BY/ODbL).
    if (location == about && (session is SignedOut || session is SignedIn)) {
      return null;
    }
    switch (session) {
      case SessionLoading():
        return location == splash ? null : splash;
      case SessionFailed():
        return location == sessionError ? null : sessionError;
      case SignedOut():
        return _public.contains(location) ? null : login;
      case SignedIn(account: null):
        return location == onboarding ? null : onboarding;
      case SignedIn(:final account?):
        final home = homeFor(account);
        // Un vet no aprobado solo puede estar en su pantalla de espera.
        if (home == vetPending) return location == vetPending ? null : home;
        if (location == vetPending) return home;
        if (location == home || location.startsWith('$home/')) return null;
        return home;
    }
  }
}
