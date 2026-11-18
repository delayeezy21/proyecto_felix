import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Reloj falso: el envío "tarda" [spent] y las esperas se registran sin
/// dormir. Así el test no depende del temporizador real (era intermitente).
class _FakeClock {
  new(this.spent);

  final Duration spent;
  final waits = <Duration>[];

  Duration elapsed() => spent;

  Future<void> wait(Duration d) async => waits.add(d);

  /// Tiempo total que vería el cliente.
  Duration get total => waits.fold(spent, (a, b) => a + b);
}

void main() {
  const min = Duration(milliseconds: 120);

  Future<void> run(Future<void> Function() send, _FakeClock clock) =>
      neutralPasswordReset(
        send,
        minDuration: min,
        elapsed: clock.elapsed,
        wait: clock.wait,
      );

  test('el 429 over_email_send_rate_limit se trata como envío correcto', () {
    expect(
      run(
        () async => throw const AuthException(
          'For security purposes, you can only request this after 60 seconds',
          statusCode: '429',
          code: 'over_email_send_rate_limit',
        ),
        _FakeClock(Duration.zero),
      ),
      completes,
    );
  });

  test('cuenta existente e inexistente tardan al menos lo mismo', () async {
    // Inexistente: GoTrue responde en ~5 ms.
    final fast = _FakeClock(const Duration(milliseconds: 5));
    await run(() async {}, fast);
    // Existente con 429: ~70 ms.
    final limited = _FakeClock(const Duration(milliseconds: 70));
    await run(
      () async =>
          throw const AuthException('x', code: 'over_email_send_rate_limit'),
      limited,
    );
    expect(fast.total, min);
    expect(limited.total, min);
    expect(fast.waits.single, const Duration(milliseconds: 115));
  });

  test('si el envío ya tardó más que el mínimo, no espera', () async {
    final slow = _FakeClock(const Duration(milliseconds: 300));
    await run(() async {}, slow);
    expect(slow.waits, isEmpty);
  });

  test('otros errores se propagan (después de la espera mínima)', () async {
    final clock = _FakeClock(const Duration(milliseconds: 10));
    await expectLater(
      run(
        () async =>
            throw const AuthException('x', code: 'over_request_rate_limit'),
        clock,
      ),
      throwsA(isA<AuthException>()),
    );
    expect(clock.total, min);
  });

  test('la espera mínima por defecto es de 800 ms', () {
    expect(passwordResetMinDuration, const Duration(milliseconds: 800));
  });
}
