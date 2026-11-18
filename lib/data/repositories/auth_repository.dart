import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Error de autenticación con un mensaje listo para mostrar al usuario.
class AuthFailure implements Exception {
  const new(this.message, {this.code});

  final String message;

  /// Código de Supabase Auth (por ejemplo 'email_not_confirmed').
  final String? code;

  bool get isEmailNotConfirmed => code == 'email_not_confirmed';

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

  /// Reenvía el correo de confirmación de registro.
  Future<void> resendConfirmation({required String email});

  Future<void> signInWithGoogle();

  Future<void> signOut();

  /// Envía el enlace para restablecer la contraseña. No revela si el correo
  /// tiene cuenta (Supabase responde igual en ambos casos).
  Future<void> sendPasswordReset({required String email});

  /// Emite cada vez que el usuario vuelve del enlace de recuperación (evento
  /// `passwordRecovery`): ya tiene sesión y debe fijar una contraseña nueva.
  Stream<void> watchPasswordRecovery();

  /// Cambia la contraseña del usuario con sesión (tras la recuperación).
  Future<void> updatePassword(String password);
}

/// Deep link de retorno para OAuth y confirmación de email en móvil.
const authRedirectUrl = 'cl.proyectofelix://login-callback';

/// A dónde vuelve el usuario tras confirmar el correo o tras OAuth: en Web, el
/// mismo origen desde el que se abrió la app (localhost o la IP de la red
/// local); en móvil y escritorio, el deep link.
String authRedirectTarget() => kIsWeb ? Uri.base.origin : authRedirectUrl;

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
        emailRedirectTo: authRedirectTarget(),
      ),
    );
    return res.session == null
        ? SignUpResult.confirmationRequired
        : SignUpResult.signedIn;
  }

  @override
  Future<void> resendConfirmation({required String email}) => _guard(
    () => _auth.resend(
      type: OtpType.signup,
      email: email.trim(),
      emailRedirectTo: authRedirectTarget(),
    ),
  );

  @override
  Future<void> signInWithGoogle() => _guard(
    () => _auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: authRedirectTarget(),
    ),
  );

  @override
  Future<void> signOut() => _guard(_auth.signOut);

  @override
  Future<void> sendPasswordReset({required String email}) => _guard(
    () => neutralPasswordReset(
      () => _auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: authRedirectTarget(),
      ),
    ),
  );

  @override
  Stream<void> watchPasswordRecovery() => _auth.onAuthStateChange
      .where((s) => s.event == AuthChangeEvent.passwordRecovery)
      .map((_) {});

  @override
  Future<void> updatePassword(String password) =>
      _guard(() => _auth.updateUser(UserAttributes(password: password)));

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AuthException catch (e) {
      throw AuthFailure(authErrorMessage(e.code, e.message), code: e.code);
    }
  }
}

/// Tiempo mínimo de respuesta de "Olvidé mi contraseña" (QA-F5-03).
const passwordResetMinDuration = Duration(milliseconds: 800);

/// Envía el enlace sin revelar si el correo tiene cuenta (QA-F5-03):
/// - GoTrue responde 429 `over_email_send_rate_limit` solo a cuentas
///   existentes que repiten el pedido: se trata como un envío correcto;
/// - la respuesta tarda al menos [minDuration] (iguala el tiempo de una
///   cuenta existente, ~70 ms, con el de una inexistente, ~5 ms).
/// Otros errores (red, `over_request_rate_limit` por IP) se propagan después
/// de la misma espera. La mitigación completa es captcha en la nube
/// (docs/despliegue-beta.md).
Future<void> neutralPasswordReset(
  Future<void> Function() send, {
  Duration minDuration = passwordResetMinDuration,
}) async {
  final watch = Stopwatch()..start();
  Object? error;
  StackTrace? trace;
  try {
    await send();
  } on AuthException catch (e, st) {
    if (e.code != 'over_email_send_rate_limit') {
      error = e;
      trace = st;
    }
  }
  final left = minDuration - watch.elapsed;
  if (left > Duration.zero) await Future<void>.delayed(left);
  if (error != null) Error.throwWithStackTrace(error, trace!);
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
  'same_password' => 'La contraseña nueva debe ser distinta de la anterior.',
  'otp_expired' => 'El enlace venció. Pide uno nuevo.',
  _ => 'No se pudo completar la operación. Inténtalo de nuevo.',
};
