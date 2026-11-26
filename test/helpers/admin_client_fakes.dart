import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/admin_client_repository.dart';
import 'package:proyecto_felix/domain/models/admin_client.dart';

/// Abre una sección del panel del admin: en pantallas angostas abre antes el
/// menú lateral (botón `admin-menu`).
Future<void> openAdminSection(WidgetTester tester, String label) async {
  final menu = find.byKey(const Key('admin-menu'));
  if (menu.evaluate().isNotEmpty) {
    await tester.tap(menu);
    await tester.pumpAndSettle();
  }
  final item = find.byKey(Key('admin-nav-$label'));
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
}

AdminClient adminClient({
  String id = 'o1',
  String name = 'Ana Ficticia',
  bool blocked = false,
  int visits = 2,
}) => AdminClient(
  userId: id,
  displayName: name,
  email: blocked ? null : '$id@test.local',
  communeName: blocked ? null : 'San Miguel',
  createdAt: DateTime(2026, 11, 20),
  visitsTotal: visits,
  visitsCompleted: 1,
  blocked: blocked,
);

class FakeAdminClientRepository implements AdminClientRepository {
  List<AdminClient> clients = [];
  final details = <String, AdminClientDetail>{};
  final searches = <String?>[];
  Exception? nextFailure;

  @override
  Future<List<AdminClient>> list({String? search, int limit = 200}) async {
    searches.add(search);
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
    final q = (search ?? '').toLowerCase();
    return [
      for (final c in clients)
        if (q.isEmpty || c.displayName.toLowerCase().contains(q)) c,
    ];
  }

  @override
  Future<AdminClientDetail> detail(String userId) async {
    final d = details[userId];
    if (d == null) throw const AdminClientFailure('Cliente no encontrado');
    return d;
  }
}
