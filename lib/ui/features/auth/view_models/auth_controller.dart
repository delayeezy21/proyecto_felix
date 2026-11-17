import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';

/// Acciones de autenticación. El estado indica si hay una operación en curso
/// y el último error (`AuthFailure`).
class AuthController extends AsyncNotifier<void> {
  @override
  void build() {}

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  Future<bool> signIn({required String email, required String password}) =>
      _run(() => _repo.signInWithEmail(email: email, password: password));

  Future<bool> signInWithGoogle() => _run(_repo.signInWithGoogle);

  Future<bool> resendConfirmation({required String email}) =>
      _run(() => _repo.resendConfirmation(email: email));

  Future<bool> signOut() {
    ref.read(passwordRecoveryProvider.notifier).finish();
    return _run(_repo.signOut);
  }

  Future<bool> sendPasswordReset({required String email}) =>
      _run(() => _repo.sendPasswordReset(email: email));

  /// Fija la contraseña nueva y cierra el modo recuperación.
  Future<bool> updatePassword(String password) async {
    final ok = await _run(() => _repo.updatePassword(password));
    if (ok && ref.mounted) {
      ref.read(passwordRecoveryProvider.notifier).finish();
    }
    return ok;
  }

  /// Devuelve el resultado, o null si falló (el error queda en `state`).
  Future<SignUpResult?> signUp({
    required String email,
    required String password,
  }) async {
    SignUpResult? result;
    final ok = await _run(() async {
      result = await _repo.signUpWithEmail(email: email, password: password);
    });
    return ok ? result : null;
  }

  Future<bool> _run(Future<void> Function() action) async {
    state = const AsyncLoading();
    final next = await AsyncValue.guard(action);
    if (ref.mounted) state = next;
    return !next.hasError;
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, void>(
  AuthController.new,
);

/// true mientras el usuario volvió del enlace de recuperación y aún no fija
/// su contraseña nueva. El router lo lleva a la pantalla de nueva contraseña.
class PasswordRecoveryController extends Notifier<bool> {
  @override
  bool build() {
    final sub = ref
        .watch(authRepositoryProvider)
        .watchPasswordRecovery()
        .listen((_) => state = true);
    ref.onDispose(sub.cancel);
    return false;
  }

  void finish() => state = false;
}

final passwordRecoveryProvider =
    NotifierProvider<PasswordRecoveryController, bool>(
      PasswordRecoveryController.new,
    );

/// Mensaje legible de un error de autenticación o registro.
String errorMessage(Object error) => switch (error) {
  AuthFailure(:final message) => message,
  _ => 'Ocurrió un error inesperado. Inténtalo de nuevo.',
};
