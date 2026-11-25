import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/data/services/recovery_flag_store.dart';

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
    ref.read(accountBlockedSignalProvider).clear();
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
///
/// La marca se guarda (con el id del usuario) en el almacenamiento local, así
/// que una recarga de la web sigue en /reset-password (QA O-2).
class PasswordRecoveryController extends Notifier<bool> {
  @override
  bool build() {
    final auth = ref.watch(authRepositoryProvider);
    final store = ref.watch(recoveryFlagStoreProvider);
    final sub = auth.watchPasswordRecovery().listen((_) async {
      state = true;
      await store.write(await auth.watchUserId().first);
    });
    ref.onDispose(sub.cancel);
    unawaited(_restore(auth, store));
    return false;
  }

  Future<void> _restore(AuthRepository auth, RecoveryFlagStore store) async {
    final stored = await store.read();
    if (stored == null) return;
    final uid = await auth.watchUserId().first;
    if (!ref.mounted) return;
    if (uid == stored) {
      state = true;
    } else {
      // La marca era de otra sesión: se descarta.
      await store.write(null);
    }
  }

  void finish() {
    state = false;
    unawaited(ref.read(recoveryFlagStoreProvider).write(null));
  }
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
