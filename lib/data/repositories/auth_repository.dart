import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error de autenticación con un mensaje listo para mostrar al usuario.
class AuthFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'AuthFailure: $message';
}

/// Resultado del registro con email.
enum SignUpResult {
  /// Hay que confirmar el correo antes de entrar.
  confirmationRequired,

  /// La sesión quedó abierta (confirmación desactivada).
  signedIn,
}

abstract interface class AuthRepository {
  /// Emite el id del usuario actual (o null) al suscribirse y en cada cambio.
  Stream<String?> watchUserId();

  Future<void> signInWithEmail({
    required String email,
    required String password,
  });

  Future<SignUpResult> signUpWithEmail({
    required String email,
    required String password,
  });

  Future<void> signInWithGoogle();

  Future<void> signOut();
}

/// Deep link de retorno para OAuth y confirmación de email en móvil.
const authRedirectUrl = 'cl.proyectofelix://login-callback';

class SupabaseAuthRepository implements AuthRepository {
  new(this._auth);

  final GoTrueClient _auth;

  @override
  Stream<String?> watchUserId() async* {
    yield _auth.currentUser?.id;
    yield* _auth.onAuthStateChange.map((s) => s.session?.user.id);
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) => _guard(
    () => _auth.signInWithPassword(email: email.trim(), password: password),
  );

  @override
  Future<SignUpResult> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    final res = await _guard(
      () => _auth.signUp(
        email: email.trim(),
        password: password,
        emailRedirectTo: kIsWeb ? null : authRedirectUrl,
      ),
    );
    return res.session == null
        ? SignUpResult.confirmationRequired
        : SignUpResult.signedIn;
  }

  @override
  Future<void> signInWithGoogle() => _guard(
    () => _auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: kIsWeb ? null : authRedirectUrl,
    ),
  );

  @override
  Future<void> signOut() => _guard(_auth.signOut);

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AuthException catch (e) {
      throw AuthFailure(authErrorMessage(e.code, e.message));
    }
  }
}

/// Traduce los códigos de Supabase Auth a mensajes en español.
@visibleForTesting
String authErrorMessage(String? code, String fallback) => switch (code) {
  'invalid_credentials' => 'Correo o contraseña incorrectos.',
  'email_not_confirmed' => 'Confirma tu correo antes de entrar.',
  'user_already_exists' ||
  'email_exists' => 'Ya existe una cuenta con ese correo.',
  'weak_password' =>
    'La contraseña debe tener 8 caracteres o más, con mayúsculas, '
        'minúsculas y números.',
  'over_email_send_rate_limit' ||
  'over_request_rate_limit' => 'Demasiados intentos. Espera unos minutos.',
  'provider_disabled' => 'Este método de inicio de sesión no está habilitado.',
  _ => 'No se pudo completar la operación. Inténtalo de nuevo.',
};
