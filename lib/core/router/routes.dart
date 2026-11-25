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
  static String ownerPetRecord(String id) => '/owner/pets/$id/record';
  static String ownerPetRecordLog(String id) => '/owner/pets/$id/record/log';
  static const ownerBook = '/owner/book';

  /// Agendar con mascota y dirección ya elegidas, desde hoy (sin vet para una
  /// urgencia: "Agendar primera hora libre").
  static String ownerBookFrom({String? petId, String? addressId}) => Uri(
    path: ownerBook,
    queryParameters: {'from': 'urgent', 'pet': ?petId, 'address': ?addressId},
  ).toString();
  static const ownerUrgent = '/owner/urgent';
  static const ownerClinics = '/owner/clinics';
  static String ownerClinicsNear(String? communeName) => Uri(
    path: ownerClinics,
    queryParameters: {'commune': ?communeName},
  ).toString();
  static String ownerVisit(String id) => '/owner/visits/$id';
  static String ownerVisitPay(String id) => '/owner/visits/$id/pay';
  static const vet = '/vet';
  static const vetPending = '/vet/pending';
  static const vetVisits = '/vet/visits';
  static const vetBase = '/vet/base';

  /// Ficha vista por el vet desde su visita.
  static String vetRecord(String petId, String visitId) =>
      '/vet/record/$petId?visit=$visitId';
  static const admin = '/admin';
  static const foundation = '/foundation';

  /// Privacidad y datos (los tres roles; también el vet en revisión).
  static const privacy = '/privacy';
  static const privacyPolicy = '/privacy/policy';

  /// Cuenta en proceso de borrado: solo cancelar, exportar o salir.
  static const accountBlocked = '/account-blocked';

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
  ///
  /// [accountBlocked]: alguna llamada respondió `account_blocked` (hay una
  /// solicitud de eliminación vigente).
  static String? redirect(
    SessionSnapshot session,
    String location, {
    bool recoveringPassword = false,
    bool accountBlocked = false,
  }) {
    // Cuenta en proceso de borrado: solo su pantalla (cancelar, exportar o
    // salir), antes que cualquier otra regla.
    if (session is SignedIn && (session.blocked || accountBlocked)) {
      return location == AppRoutes.accountBlocked
          ? null
          : AppRoutes.accountBlocked;
    }
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
        // Privacidad y datos: para todo rol (también el vet en revisión).
        if (location == privacy || location.startsWith('$privacy/')) {
          return null;
        }
        // Un vet no aprobado solo puede estar en su pantalla de espera.
        if (home == vetPending) return location == vetPending ? null : home;
        if (location == vetPending) return home;
        if (location == home || location.startsWith('$home/')) return null;
        return home;
    }
  }
}
