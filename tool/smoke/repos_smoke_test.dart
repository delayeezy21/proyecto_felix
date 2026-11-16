// Smoke test de los repositorios REALES contra Supabase local.
//
// Detecta lo que los falsos de test/ no ven: consultas que fallan con datos y
// RLS reales (p. ej. el admin ve todas las filas de user_roles).
//
// Uso (con `supabase start`):
//   flutter test tool/smoke/repos_smoke_test.dart \
//     --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
//     --dart-define=SUPABASE_SERVICE_KEY=...
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = 'http://127.0.0.1:54321';
const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const _service = String.fromEnvironment('SUPABASE_SERVICE_KEY');
const _password = 'Felix2026';

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

/// Crea un usuario confirmado y devuelve un cliente con su sesión.
Future<SupabaseClient> _newUser(String tag) async {
  final email =
      'smoke-$tag-${DateTime.now().microsecondsSinceEpoch}@test.local';
  await _client(_service).auth.admin.createUser(
    AdminUserAttributes(email: email, password: _password, emailConfirm: true),
  );
  final c = _client(_key);
  await c.auth.signInWithPassword(email: email, password: _password);
  return c;
}

Future<LegalVersions> _legal(SupabaseClient c) =>
    SupabaseProfileRepository(c).fetchLegalVersions();

void main() {
  setUpAll(() {
    if (_key.isEmpty || _service.isEmpty) {
      fail(
        'Faltan --dart-define SUPABASE_PUBLISHABLE_KEY / SUPABASE_SERVICE_KEY',
      );
    }
  });

  test('dueño: registro con comuna y cuenta real', () async {
    final c = await _newUser('owner');
    final repo = SupabaseProfileRepository(c);
    expect(await repo.fetchAccount(), isNull, reason: 'sin registro aún');

    final communes = await SupabaseCatalogRepository(c).communes(13);
    await repo.completeRegistration(
      role: AppRole.owner,
      displayName: 'Smoke Dueño',
      phone: '+56 9 1111 2222',
      legal: await _legal(c),
      marketingConsent: true,
      communeId: communes.first.id,
    );
    final account = await repo.fetchAccount();
    expect(account?.role, AppRole.owner);
    expect(account?.displayName, 'Smoke Dueño');
  });

  test('vet: queda pendiente', () async {
    final c = await _newUser('vet');
    final repo = SupabaseProfileRepository(c);
    await repo.completeRegistration(
      role: AppRole.vet,
      displayName: 'Smoke Vet',
      phone: null,
      legal: await _legal(c),
      marketingConsent: false,
    );
    final account = await repo.fetchAccount();
    expect(account?.role, AppRole.vet);
    expect(account?.vetStatus, VetStatus.pending);
  });

  test('admin: cuenta y panel con datos reales', () async {
    final c = await _newUser('admin');
    await _client(_service)
        .from('user_roles')
        .insert({'user_id': c.auth.currentUser!.id, 'role': 'admin'});

    // Regresión: el admin ve todas las filas de user_roles.
    final account = await SupabaseProfileRepository(c).fetchAccount();
    expect(account?.role, AppRole.admin);

    final cat = SupabaseCatalogRepository(c);
    expect((await cat.regions()).length, 16);
    expect((await cat.communes(13)).length, 52);
    for (final k in CatalogKind.values) {
      expect(await cat.items(k), isNotEmpty, reason: k.name);
    }
    final tariffs = await cat.tariffs();
    expect(tariffs, isNotEmpty);
    await cat.updateTariffPrice(tariffs.first.id, tariffs.first.basePrice);
    expect((await cat.currentPricing()).commissionPct, greaterThan(0));
    await cat.clinics();
  });
}
