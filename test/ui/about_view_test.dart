import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/attributions.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeUrlOpener opener;

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository(
      auth,
      accounts: {'o1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
    opener = FakeUrlOpener();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 2000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, opener: opener),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sin sesión, desde el login muestra la atribución', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('login-about')));
    await tester.pumpAndSettle();
    expect(find.text('Acerca de y licencias'), findsOneWidget);
    expect(find.text('Límites comunales de Chile'), findsOneWidget);
    expect(find.textContaining('geoBoundaries'), findsOneWidget);
    expect(find.text('Licencia CC BY 3.0 IGO'), findsOneWidget);
    expect(find.text('Licencia ODbL 1.0'), findsNWidgets(2));
    expect(find.textContaining('colaboradores de OpenStreetMap'), findsWidgets);

    await tester.tap(find.text('Licencia CC BY 3.0 IGO'));
    await tester.pumpAndSettle();
    expect(opener.opened, [dataAttributions.first.licenseUrl]);
  });

  testWidgets('el dueño llega desde su perfil', (tester) async {
    auth.emit('o1');
    await open(tester);
    await tester.tap(find.byKey(const Key('owner-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-about')));
    await tester.pumpAndSettle();
    expect(find.text('Límites comunales de Chile'), findsOneWidget);
    expect(find.byKey(const Key('about-oss-licenses')), findsOneWidget);
  });

  test('la ruta se permite con y sin sesión, no mientras carga', () {
    const owner = SignedIn(Account(role: AppRole.owner, displayName: 'Ana'));
    expect(AppRoutes.redirect(const SignedOut(), AppRoutes.about), isNull);
    expect(AppRoutes.redirect(owner, AppRoutes.about), isNull);
    expect(
      AppRoutes.redirect(const SessionLoading(), AppRoutes.about),
      AppRoutes.splash,
    );
  });
}
