import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository(auth);
  });

  Future<void> openLogin(WidgetTester tester) async {
    await tester.pumpWidget(testApp(auth: auth, profiles: profiles));
    await tester.pumpAndSettle();
  }

  group('Login', () {
    testWidgets('valida campos vacíos sin llamar al backend', (tester) async {
      await openLogin(tester);
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pump();
      expect(find.text('Ingresa tu correo'), findsOneWidget);
      expect(find.text('Ingresa tu contraseña'), findsOneWidget);
      expect(auth.signInCalls, isEmpty);
    });

    testWidgets('con datos válidos inicia sesión y va al onboarding', (
      tester,
    ) async {
      await openLogin(tester);
      await tester.enterText(find.byKey(const Key('login-email')), 'a@b.cl');
      await tester.enterText(
        find.byKey(const Key('login-password')),
        'Secreta123',
      );
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(auth.signInCalls, [('a@b.cl', 'Secreta123')]);
      expect(find.text('Completa tu registro'), findsOneWidget);
    });

    testWidgets('muestra el error del backend en español', (tester) async {
      auth.nextFailure = const AuthFailure('Correo o contraseña incorrectos.');
      await openLogin(tester);
      await tester.enterText(find.byKey(const Key('login-email')), 'a@b.cl');
      await tester.enterText(find.byKey(const Key('login-password')), 'x');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Correo o contraseña incorrectos.'), findsOneWidget);
    });

    testWidgets('cuenta sin confirmar: ofrece reenviar y avisa de Mailpit', (
      tester,
    ) async {
      auth.nextFailure = const AuthFailure(
        'Confirma tu correo antes de entrar.',
        code: 'email_not_confirmed',
      );
      await openLogin(tester);
      await tester.enterText(find.byKey(const Key('login-email')), 'a@b.cl');
      await tester.enterText(find.byKey(const Key('login-password')), 'x');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Confirma tu correo antes de entrar.'), findsOneWidget);
      expect(find.byKey(const Key('dev-mail-hint')), findsOneWidget);

      await tester.tap(find.byKey(const Key('login-resend')));
      await tester.pumpAndSettle();
      expect(auth.resendCalls, ['a@b.cl']);
      expect(find.byKey(const Key('login-resent')), findsOneWidget);
    });

    testWidgets('credenciales inválidas no ofrecen reenviar', (tester) async {
      auth.nextFailure = const AuthFailure(
        'Correo o contraseña incorrectos.',
        code: 'invalid_credentials',
      );
      await openLogin(tester);
      await tester.enterText(find.byKey(const Key('login-email')), 'a@b.cl');
      await tester.enterText(find.byKey(const Key('login-password')), 'x');
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-resend')), findsNothing);
    });

    testWidgets('sin Google habilitado no muestra el botón', (tester) async {
      await openLogin(tester);
      expect(find.byKey(const Key('login-google')), findsNothing);
    });

    testWidgets('con Google habilitado el botón llama al repositorio', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          env: const Env(
            supabaseUrl: 'http://127.0.0.1:54321',
            supabasePublishableKey: 'clave-de-prueba',
            mapProvider: MapProvider.osm,
            mapsApiKey: '',
            googleAuthEnabled: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('login-google')));
      await tester.tap(find.byKey(const Key('login-google')));
      await tester.pumpAndSettle();
      expect(auth.googleCalls, 1);
    });
  });

  group('Registro', () {
    Future<void> openSignUp(WidgetTester tester) async {
      await openLogin(tester);
      await tester.tap(find.byKey(const Key('login-go-signup')));
      await tester.pumpAndSettle();
    }

    testWidgets('exige contraseña robusta y que coincidan', (tester) async {
      await openSignUp(tester);
      await tester.enterText(find.byKey(const Key('signup-email')), 'a@b.cl');
      await tester.enterText(find.byKey(const Key('signup-password')), 'abc');
      await tester.enterText(find.byKey(const Key('signup-confirm')), 'abcd');
      await tester.tap(find.byKey(const Key('signup-submit')));
      await tester.pump();
      expect(find.text('Mínimo 8 caracteres'), findsOneWidget);
      expect(find.text('Las contraseñas no coinciden'), findsOneWidget);
      expect(auth.signUpCalls, isEmpty);
    });

    testWidgets('pide confirmar el correo tras registrarse', (tester) async {
      await openSignUp(tester);
      await tester.enterText(find.byKey(const Key('signup-email')), 'a@b.cl');
      await tester.enterText(
        find.byKey(const Key('signup-password')),
        'Felix2026',
      );
      await tester.enterText(
        find.byKey(const Key('signup-confirm')),
        'Felix2026',
      );
      await tester.tap(find.byKey(const Key('signup-submit')));
      await tester.pumpAndSettle();
      expect(auth.signUpCalls, [('a@b.cl', 'Felix2026')]);
      expect(find.byKey(const Key('signup-confirmation')), findsOneWidget);
      expect(find.byKey(const Key('dev-mail-hint')), findsOneWidget);
    });
  });
}
