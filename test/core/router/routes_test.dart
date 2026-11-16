import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/models/account.dart';

const _owner = Account(role: AppRole.owner, displayName: 'Ana');
const _vetPending = Account(
  role: AppRole.vet,
  displayName: 'Vera',
  vetStatus: VetStatus.pending,
);
const _vetApproved = Account(
  role: AppRole.vet,
  displayName: 'Vera',
  vetStatus: VetStatus.approved,
);
const _admin = Account(role: AppRole.admin, displayName: 'admin');

void main() {
  String? go(SessionSnapshot s, String loc) => AppRoutes.redirect(s, loc);

  group('cargando', () {
    test('todo va al splash', () {
      expect(go(const SessionLoading(), AppRoutes.owner), AppRoutes.splash);
      expect(go(const SessionLoading(), AppRoutes.splash), isNull);
    });
  });

  group('cuenta que no se pudo cargar', () {
    test('va a la pantalla de error, nunca queda en el splash', () {
      expect(
        go(const SessionFailed(), AppRoutes.splash),
        AppRoutes.sessionError,
      );
      expect(
        go(const SessionFailed(), AppRoutes.admin),
        AppRoutes.sessionError,
      );
      expect(go(const SessionFailed(), AppRoutes.sessionError), isNull);
    });
  });

  group('sin sesión', () {
    test('puede estar en login y registro', () {
      expect(go(const SignedOut(), AppRoutes.login), isNull);
      expect(go(const SignedOut(), AppRoutes.signUp), isNull);
    });
    test('cualquier ruta privada lleva a login', () {
      for (final r in [
        AppRoutes.owner,
        AppRoutes.vet,
        AppRoutes.admin,
        AppRoutes.onboarding,
        AppRoutes.splash,
      ]) {
        expect(go(const SignedOut(), r), AppRoutes.login, reason: r);
      }
    });
  });

  group('autenticado sin registro completo', () {
    test('siempre va al onboarding', () {
      expect(go(const SignedIn(null), AppRoutes.owner), AppRoutes.onboarding);
      expect(go(const SignedIn(null), AppRoutes.login), AppRoutes.onboarding);
      expect(go(const SignedIn(null), AppRoutes.onboarding), isNull);
    });
  });

  group('con rol', () {
    test('dueño va a su inicio y no entra a zonas de otros roles', () {
      expect(go(const SignedIn(_owner), AppRoutes.login), AppRoutes.owner);
      expect(go(const SignedIn(_owner), AppRoutes.owner), isNull);
      expect(go(const SignedIn(_owner), AppRoutes.admin), AppRoutes.owner);
      expect(go(const SignedIn(_owner), AppRoutes.vet), AppRoutes.owner);
      expect(go(const SignedIn(_owner), AppRoutes.onboarding), AppRoutes.owner);
    });

    test('vet pendiente solo ve su pantalla de espera', () {
      expect(
        go(const SignedIn(_vetPending), AppRoutes.vet),
        AppRoutes.vetPending,
      );
      expect(go(const SignedIn(_vetPending), AppRoutes.vetPending), isNull);
      expect(
        go(const SignedIn(_vetPending), AppRoutes.owner),
        AppRoutes.vetPending,
      );
    });

    test('vet aprobado va a su panel y sale de la espera', () {
      expect(go(const SignedIn(_vetApproved), AppRoutes.vet), isNull);
      expect(
        go(const SignedIn(_vetApproved), AppRoutes.vetPending),
        AppRoutes.vet,
      );
    });

    test('admin entra a administración y a sus subrutas', () {
      expect(go(const SignedIn(_admin), AppRoutes.admin), isNull);
      expect(go(const SignedIn(_admin), '${AppRoutes.admin}/vets'), isNull);
      expect(go(const SignedIn(_admin), AppRoutes.owner), AppRoutes.admin);
    });

    test('vet rechazado o suspendido no accede al panel', () {
      for (final status in [VetStatus.rejected, VetStatus.suspended]) {
        final vet = Account(
          role: AppRole.vet,
          displayName: 'V',
          vetStatus: status,
        );
        expect(go(SignedIn(vet), AppRoutes.vet), AppRoutes.vetPending);
      }
    });
  });
}
