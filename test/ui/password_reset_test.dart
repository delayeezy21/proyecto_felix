import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeRecoveryFlagStore store;

  setUp(() {
    auth = FakeAuthRepository();
    store = FakeRecoveryFlagStore();
    profiles = FakeProfileRepository(
      auth,
      accounts: {'o1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, recoveryStore: store),
    );
    await tester.pumpAndSettle();
  }

  group('Olvidé mi contraseña', () {
    testWidgets('desde el login pide el correo y envía el enlace', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('login-forgot')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('forgot-submit')));
      await tester.pump();
      expect(find.text('Ingresa tu correo'), findsOneWidget);
      expect(auth.resetCalls, isEmpty);

      await tester.enterText(
        find.byKey(const Key('forgot-email')),
        ' ana@test.local ',
      );
      await tester.tap(find.byKey(const Key('forgot-submit')));
      await tester.pumpAndSettle();
      expect(auth.resetCalls, ['ana@test.local']);
      // Mismo mensaje exista o no la cuenta (no revela correos).
      expect(find.byKey(const Key('forgot-sent')), findsOneWidget);
      expect(
        find.textContaining('Si ana@test.local tiene una cuenta'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dev-mail-hint')), findsOneWidget);

      await tester.tap(find.byKey(const Key('forgot-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-submit')), findsOneWidget);
    });

    testWidgets('muestra el error del backend', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('login-forgot')));
      await tester.pumpAndSettle();
      auth.nextFailure = const AuthFailure(
        'Demasiados intentos. Espera unos minutos.',
      );
      await tester.enterText(
        find.byKey(const Key('forgot-email')),
        'ana@test.local',
      );
      await tester.tap(find.byKey(const Key('forgot-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('Demasiados intentos. Espera unos minutos.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('forgot-sent')), findsNothing);
    });
  });

  group('Nueva contraseña (al volver del enlace)', () {
    testWidgets('lleva a la pantalla, valida y guarda la contraseña', (
      tester,
    ) async {
      await open(tester);
      auth.emitRecovery('o1');
      await tester.pumpAndSettle();
      expect(find.text('Nueva contraseña'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('reset-password')), 'corta');
      await tester.enterText(find.byKey(const Key('reset-confirm')), 'otra');
      await tester.tap(find.byKey(const Key('reset-submit')));
      await tester.pump();
      expect(find.text('Mínimo 8 caracteres'), findsOneWidget);
      expect(find.text('Las contraseñas no coinciden'), findsOneWidget);
      expect(auth.passwordUpdates, isEmpty);

      await tester.enterText(
        find.byKey(const Key('reset-password')),
        'NuevaClave2026',
      );
      await tester.enterText(
        find.byKey(const Key('reset-confirm')),
        'NuevaClave2026',
      );
      await tester.tap(find.byKey(const Key('reset-submit')));
      await tester.pumpAndSettle();
      expect(auth.passwordUpdates, ['NuevaClave2026']);
      expect(find.text('Tu contraseña se actualizó.'), findsOneWidget);
      // Termina la recuperación: queda en su inicio.
      expect(find.text('Hola, Ana'), findsOneWidget);
    });

    testWidgets('si falla, sigue en la pantalla con el error', (tester) async {
      await open(tester);
      auth.emitRecovery('o1');
      await tester.pumpAndSettle();
      auth.nextFailure = const AuthFailure(
        'La contraseña nueva debe ser distinta de la anterior.',
      );
      for (final k in ['reset-password', 'reset-confirm']) {
        await tester.enterText(find.byKey(Key(k)), 'NuevaClave2026');
      }
      await tester.tap(find.byKey(const Key('reset-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('La contraseña nueva debe ser distinta de la anterior.'),
        findsOneWidget,
      );
      expect(find.text('Nueva contraseña'), findsOneWidget);
    });

    testWidgets('cancelar cierra la sesión', (tester) async {
      await open(tester);
      auth.emitRecovery('o1');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reset-cancel')));
      await tester.pumpAndSettle();
      expect(auth.userId, isNull);
      expect(find.byKey(const Key('login-submit')), findsOneWidget);
    });
  });

  group('modo recuperación persistente (O-2)', () {
    testWidgets('el evento guarda la marca y al terminar se borra', (
      tester,
    ) async {
      await open(tester);
      auth.emitRecovery('o1');
      await tester.pumpAndSettle();
      expect(store.userId, 'o1');
      for (final k in ['reset-password', 'reset-confirm']) {
        await tester.enterText(find.byKey(Key(k)), 'NuevaClave2026');
      }
      await tester.tap(find.byKey(const Key('reset-submit')));
      await tester.pumpAndSettle();
      expect(store.userId, isNull);
    });

    testWidgets('al recargar con la marca del mismo usuario sigue en la '
        'pantalla de nueva contraseña', (tester) async {
      auth.emit('o1');
      store.userId = 'o1';
      await open(tester);
      expect(find.text('Nueva contraseña'), findsOneWidget);
    });

    testWidgets('una marca de otro usuario se descarta', (tester) async {
      auth.emit('o1');
      store.userId = 'otro';
      await open(tester);
      expect(find.text('Hola, Ana'), findsOneWidget);
      expect(store.userId, isNull);
    });
  });

  group('redirección en modo recuperación', () {
    const owner = SignedIn(Account(role: AppRole.owner, displayName: 'Ana'));

    test('con sesión de recuperación solo se permite la nueva contraseña', () {
      expect(
        AppRoutes.redirect(owner, AppRoutes.owner, recoveringPassword: true),
        AppRoutes.resetPassword,
      );
      expect(
        AppRoutes.redirect(
          owner,
          AppRoutes.resetPassword,
          recoveringPassword: true,
        ),
        isNull,
      );
    });

    test('sin recuperación, la pantalla de nueva contraseña no se usa', () {
      expect(
        AppRoutes.redirect(owner, AppRoutes.resetPassword),
        AppRoutes.owner,
      );
      expect(
        AppRoutes.redirect(const SignedOut(), AppRoutes.resetPassword),
        AppRoutes.login,
      );
    });

    test('"Olvidé mi contraseña" es pública', () {
      expect(
        AppRoutes.redirect(const SignedOut(), AppRoutes.forgotPassword),
        isNull,
      );
    });
  });
}
