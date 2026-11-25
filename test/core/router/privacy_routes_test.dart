import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/models/account.dart';

const _owner = SignedIn(Account(role: AppRole.owner, displayName: 'Ana'));
const _vetPending = SignedIn(
  Account(role: AppRole.vet, displayName: 'Vera', vetStatus: VetStatus.pending),
);
const _foundation = SignedIn(
  Account(role: AppRole.foundation, displayName: 'f@ejemplo.cl'),
);

/// Redirecciones de la fase 11: privacidad y cuenta bloqueada.
void main() {
  group('privacidad y datos', () {
    test('la abren los tres roles, también el vet en revisión', () {
      for (final s in [_owner, _vetPending, _foundation]) {
        expect(AppRoutes.redirect(s, AppRoutes.privacy), isNull);
        expect(AppRoutes.redirect(s, AppRoutes.privacyPolicy), isNull);
      }
    });

    test('sin sesión lleva al login', () {
      expect(
        AppRoutes.redirect(const SignedOut(), AppRoutes.privacy),
        AppRoutes.login,
      );
    });

    test('sin cuenta bloqueada, /account-blocked vuelve al inicio', () {
      expect(
        AppRoutes.redirect(_owner, AppRoutes.accountBlocked),
        AppRoutes.owner,
      );
    });
  });

  group('cuenta bloqueada', () {
    test('la sesión bloqueada solo puede estar en su pantalla', () {
      const blocked = SignedIn(null, blocked: true);
      for (final loc in [
        AppRoutes.owner,
        AppRoutes.onboarding,
        AppRoutes.privacy,
        AppRoutes.about,
        AppRoutes.splash,
      ]) {
        expect(AppRoutes.redirect(blocked, loc), AppRoutes.accountBlocked);
      }
      expect(AppRoutes.redirect(blocked, AppRoutes.accountBlocked), isNull);
    });

    test('una llamada con account_blocked saca de cualquier pantalla', () {
      expect(
        AppRoutes.redirect(_owner, AppRoutes.owner, accountBlocked: true),
        AppRoutes.accountBlocked,
      );
      expect(
        AppRoutes.redirect(
          _vetPending,
          AppRoutes.vetPending,
          accountBlocked: true,
        ),
        AppRoutes.accountBlocked,
      );
    });

    test('tiene prioridad sobre la recuperación de contraseña', () {
      expect(
        AppRoutes.redirect(
          _owner,
          AppRoutes.resetPassword,
          recoveringPassword: true,
          accountBlocked: true,
        ),
        AppRoutes.accountBlocked,
      );
    });

    test('sin sesión el aviso no aplica', () {
      expect(
        AppRoutes.redirect(
          const SignedOut(),
          AppRoutes.login,
          accountBlocked: true,
        ),
        isNull,
      );
    });
  });
}
