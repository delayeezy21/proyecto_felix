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

  Future<bool> signOut() => _run(_repo.signOut);

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

/// Mensaje legible de un error de autenticación o registro.
String errorMessage(Object error) => switch (error) {
  AuthFailure(:final message) => message,
  _ => 'Ocurrió un error inesperado. Inténtalo de nuevo.',
};
