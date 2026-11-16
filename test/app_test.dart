import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/domain/models/account.dart';

import 'helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository(auth);
  });

  testWidgets('sin .env muestra el aviso de configuración', (tester) async {
    await tester.pumpWidget(
      testApp(
        auth: auth,
        profiles: profiles,
        env: const Env(
          supabaseUrl: '',
          supabasePublishableKey: '',
          mapProvider: MapProvider.osm,
          mapsApiKey: '',
        ),
      ),
    );
    expect(find.text('Backend sin configurar (revisa .env)'), findsOneWidget);
  });

  testWidgets('sin sesión abre el login', (tester) async {
    await tester.pumpWidget(testApp(auth: auth, profiles: profiles));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });

  testWidgets('dueño con sesión abre su inicio con su nombre', (tester) async {
    auth = FakeAuthRepository(userId: 'u1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {'u1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
    await tester.pumpWidget(testApp(auth: auth, profiles: profiles));
    await tester.pumpAndSettle();
    expect(find.text('Hola, Ana'), findsOneWidget);
    expect(find.text('Inicio'), findsOneWidget);
  });

  testWidgets('vet pendiente ve la pantalla de revisión', (tester) async {
    auth = FakeAuthRepository(userId: 'v1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {
        'v1': const Account(
          role: AppRole.vet,
          displayName: 'Vera',
          vetStatus: VetStatus.pending,
        ),
      },
    );
    await tester.pumpWidget(testApp(auth: auth, profiles: profiles));
    await tester.pumpAndSettle();
    expect(find.text('Cuenta en revisión'), findsOneWidget);
  });

  testWidgets('sesión sin registro completo va al onboarding', (tester) async {
    auth = FakeAuthRepository(userId: 'nuevo');
    profiles = FakeProfileRepository(auth);
    await tester.pumpWidget(testApp(auth: auth, profiles: profiles));
    await tester.pumpAndSettle();
    expect(find.text('Completa tu registro'), findsOneWidget);
  });

  testWidgets('cerrar sesión vuelve al login', (tester) async {
    auth = FakeAuthRepository(userId: 'u1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {'u1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
    await tester.pumpWidget(testApp(auth: auth, profiles: profiles));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });
}
