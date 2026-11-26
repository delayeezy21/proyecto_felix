import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/admin_client_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/admin_client.dart';

import '../helpers/fakes.dart';

/// Fase 12: menú vertical del admin y la sección "Clientes".
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeAdminClientRepository clients;

  setUp(() {
    auth = FakeAuthRepository(userId: 'adm');
    profiles = FakeProfileRepository(
      auth,
      accounts: {
        'adm': const Account(role: AppRole.admin, displayName: 'Admin'),
      },
    );
    clients = FakeAdminClientRepository()
      ..clients = [
        adminClient(),
        adminClient(id: 'o2', name: 'Beto Ficticio', visits: 1),
        adminClient(
          id: 'o3',
          name: 'Cuenta en proceso de borrado',
          blocked: true,
        ),
      ]
      ..details['o1'] = AdminClientDetail(
        userId: 'o1',
        displayName: 'Ana Ficticia',
        email: 'o1@test.local',
        phone: '+56911112222',
        communeName: 'San Miguel',
        createdAt: DateTime(2026, 11, 20),
        visitsByStatus: const {'completed': 1, 'cancelled_owner': 1},
        urgentVisits: 1,
        paidTotal: 26990,
        cancelFees: 0,
        donationsTotal: 1000,
        ratingCount: 1,
        ratingAvg: 4.5,
      );
  });

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        auth: auth,
        profiles: profiles,
        adminClients: clients,
        retry: (_, _) => null,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('en pantalla ancha el menú es una lista vertical fija', (
    tester,
  ) async {
    await pump(tester, const Size(1280, 900));
    expect(find.byKey(const Key('admin-nav')), findsOneWidget);
    expect(find.byKey(const Key('admin-menu')), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    for (final group in ['Personas', 'Operación', 'Catálogos y precios']) {
      expect(find.text(group), findsOneWidget);
    }
    final vets = tester.widget<ListTile>(
      find.byKey(const Key('admin-nav-Veterinarios')),
    );
    expect(vets.selected, isTrue);
  });

  testWidgets('en teléfono el menú se abre desde el botón', (tester) async {
    await pump(tester, const Size(400, 900));
    expect(find.byKey(const Key('admin-nav')), findsNothing);
    await openAdminSection(tester, 'Clientes');
    expect(
      tester.widget<Text>(find.byKey(const Key('admin-section-title'))).data,
      'Clientes',
    );
    expect(find.text('Ana Ficticia'), findsOneWidget);
  });

  testWidgets('lista, busca y abre el detalle de un cliente', (tester) async {
    await pump(tester, const Size(1280, 900));
    await openAdminSection(tester, 'Clientes');
    expect(find.text('3 clientes'), findsOneWidget);
    expect(find.textContaining('o1@test.local'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin-clients-search')),
      'beto',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(clients.searches.last, 'beto');
    expect(find.text('1 cliente'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('admin-clients-search')), '');
    await tester.tap(find.byKey(const Key('admin-clients-search-go')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('client-o1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('client-detail')), findsOneWidget);
    expect(find.text('+56911112222'), findsOneWidget);
    expect(find.text(r'$26.990'), findsOneWidget);
    expect(find.text('2 (1 urgencias)'), findsOneWidget);
    expect(find.text('Completada: 1'), findsOneWidget);
    expect(find.text('4,5 (1)'), findsOneWidget);
    // Minimización: el detalle no muestra mascotas ni direcciones.
    expect(find.textContaining('Mascota'), findsNothing);
    await tester.tap(find.byKey(const Key('client-detail-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('client-detail')), findsNothing);
  });

  testWidgets('una cuenta en borrado no se abre', (tester) async {
    await pump(tester, const Size(1280, 900));
    await openAdminSection(tester, 'Clientes');
    final tile = tester.widget<ListTile>(find.byKey(const Key('client-o3')));
    expect(tile.onTap, isNull);
  });

  testWidgets('el error del servidor se muestra', (tester) async {
    clients.nextFailure = const AdminClientFailure('Solo el administrador.');
    await pump(tester, const Size(1280, 900));
    await openAdminSection(tester, 'Clientes');
    expect(find.text('Solo el administrador.'), findsOneWidget);
  });

  test('AdminClientDetail.fromJson lee la RPC', () {
    final d = AdminClientDetail.fromJson(const {
      'user_id': 'o9',
      'display_name': 'X',
      'created_at': '2026-11-20T10:00:00Z',
      'visits_by_status': {'completed': 2, 'expired': 1},
      'urgent_visits': 0,
      'paid_total': 50000,
      'cancel_fees': 1,
      'donations_total': 0,
      'rating_count': 0,
      'rating_avg': null,
    });
    expect(d.visitsTotal, 3);
    expect(d.ratingAvg, isNull);
    expect(d.phone, isNull);
  });
}
