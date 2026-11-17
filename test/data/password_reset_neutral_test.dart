import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  const min = Duration(milliseconds: 120);

  test('el 429 over_email_send_rate_limit se trata como envío correcto', () {
    expect(
      neutralPasswordReset(
        () async => throw const AuthException(
          'For security purposes, you can only request this after 60 seconds',
          statusCode: '429',
          code: 'over_email_send_rate_limit',
        ),
        minDuration: min,
      ),
      completes,
    );
  });

  test('cuenta existente e inexistente tardan al menos lo mismo', () async {
    Future<Duration> time(Future<void> Function() send) async {
      final w = Stopwatch()..start();
      await neutralPasswordReset(send, minDuration: min);
      return w.elapsed;
    }

    final fast = await time(() async {});
    final limited = await time(
      () async =>
          throw const AuthException('x', code: 'over_email_send_rate_limit'),
    );
    expect(fast, greaterThanOrEqualTo(min));
    expect(limited, greaterThanOrEqualTo(min));
  });

  test('otros errores se propagan (después de la espera mínima)', () async {
    final w = Stopwatch()..start();
    await expectLater(
      neutralPasswordReset(
        () async =>
            throw const AuthException('x', code: 'over_request_rate_limit'),
        minDuration: min,
      ),
      throwsA(isA<AuthException>()),
    );
    expect(w.elapsed, greaterThanOrEqualTo(min));
  });

  test('la espera mínima por defecto es de 800 ms', () {
    expect(passwordResetMinDuration, const Duration(milliseconds: 800));
  });
}
