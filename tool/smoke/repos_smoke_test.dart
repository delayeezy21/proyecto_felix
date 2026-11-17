// Smoke test de los repositorios REALES contra Supabase local.
//
// Detecta lo que los falsos de test/ no ven: consultas que fallan con datos y
// RLS reales (p. ej. el admin ve todas las filas de user_roles).
//
// Uso (con `supabase start`):
//   flutter test tool/smoke/repos_smoke_test.dart \
//     --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
//     --dart-define=SUPABASE_SERVICE_KEY=... \
//     [--dart-define=SUPABASE_URL=http://127.0.0.1:55721]  # stack aislado
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/data/repositories/owner_repositories.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/data/repositories/vet_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'http://127.0.0.1:54321',
);
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

  test('vet: solicitud completa con Storage y revisión del admin', () async {
    final c = await _newUser('vet-flow');
    await SupabaseProfileRepository(c).completeRegistration(
      role: AppRole.vet,
      displayName: 'Smoke Vet Flujo',
      phone: null,
      legal: await _legal(c),
      marketingConsent: false,
    );
    final vets = SupabaseVetRepository(c);
    final cat = SupabaseCatalogRepository(c);

    await vets.updateProfessionalData(
      bio: 'Smoke',
      university: 'Universidad de Chile',
      graduationYear: 2015,
      foreignDegree: false,
      titleVerificationCode: 'SMK-1',
    );
    final species = await cat.items(CatalogKind.species);
    final specialties = await cat.items(CatalogKind.specialties);
    await vets.setSpecies({species.first.id, species[1].id});
    await vets.setSpecies({species.first.id});
    expect(await vets.mySpeciesIds(), {species.first.id});
    await vets.setSpecialties({specialties.first.id});
    await vets.addAvailability(1, 540, 780);
    await expectLater(
      vets.addAvailability(1, 720, 900),
      throwsA(isA<VetFailure>()),
      reason: 'solape del mismo día',
    );

    await expectLater(
      vets.submitApplication(),
      throwsA(
        isA<VetFailure>().having(
          (e) => e.message,
          'message',
          contains('Falta'),
        ),
      ),
    );

    await vets.uploadDocument(
      VetDocumentKind.degreeCertificate,
      const PickedDocument(name: 'titulo.pdf', bytes: [37, 80, 68, 70]),
    );
    await vets.uploadDocument(
      VetDocumentKind.idCardFront,
      const PickedDocument(name: 'cedula.png', bytes: [137, 80, 78, 71]),
    );
    expect((await vets.myDocuments()).length, 2);
    await vets.acceptDeclaration();
    await vets.submitApplication();
    expect((await vets.myProfile()).inReview, isTrue);

    // Revisión del admin.
    final a = await _newUser('admin-flow');
    await _client(_service)
        .from('user_roles')
        .insert({'user_id': a.auth.currentUser!.id, 'role': 'admin'});
    final adminVets = SupabaseVetRepository(a);
    final pending = await adminVets.pendingApplications();
    final mine = pending.firstWhere((p) => p.userId == c.auth.currentUser!.id);
    final detail = await adminVets.applicationDetail(mine.userId);
    expect(detail.documents.length, 2);
    expect(detail.speciesNames, isNotEmpty);
    final url = await adminVets.documentUrl(
      detail.documents.first.storagePath!,
    );
    expect(url, contains('token='));
    await adminVets.review(mine.userId, approve: true, notes: 'smoke');

    final after = await vets.myProfile();
    expect(after.status, VetStatus.approved);
    expect(
      (await SupabaseProfileRepository(c).fetchAccount())?.vetStatus,
      VetStatus.approved,
    );
  });

  test('dueño: mascotas y direcciones con RLS real (fase 4)', () async {
    final c = await _newUser('owner-f4');
    final communes = await SupabaseCatalogRepository(c).communes(13);
    await SupabaseProfileRepository(c).completeRegistration(
      role: AppRole.owner,
      displayName: 'Smoke Dueño F4',
      phone: null,
      legal: await _legal(c),
      marketingConsent: false,
      communeId: communes.first.id,
    );
    final cat = SupabaseCatalogRepository(c);
    final species = await cat.items(CatalogKind.species);
    final breeds = await cat.breeds(species.first.id);

    final pets = SupabasePetRepository(c);
    await pets.create(
      PetDraft(
        name: ' Smoke ',
        speciesId: species.first.id,
        breedId: breeds.isEmpty ? null : breeds.first.id,
        birthDateApprox: DateTime(2020, 3),
        microchip: '152000000000009',
      ),
    );
    var mine = await pets.myPets();
    expect(mine, hasLength(1));
    expect(mine.single.name, 'Smoke', reason: 'el servidor recorta espacios');
    expect(mine.single.speciesName, isNotNull);
    await pets.setActive(mine.single.id, active: false);
    mine = await pets.myPets();
    expect(mine.single.active, isFalse);

    final addresses = SupabaseAddressRepository(c);
    // QA-F4-02: la comuna se deriva del punto (y el servidor la valida).
    const point = GeoPoint(-33.45, -70.66);
    final matches = await addresses.communesAt(point);
    expect(matches.first.name, 'Santiago');
    expect(communes.first.center, isNotNull, reason: 'centro embebido');
    await expectLater(
      addresses.create(
        AddressDraft(
          label: 'Incoherente',
          streetText: 'Calle Smoke 1',
          communeId: communes.firstWhere((x) => x.name == 'Alhué').id,
          point: point,
        ),
      ),
      throwsA(isA<OwnerDataFailure>()),
    );
    await addresses.create(
      AddressDraft(
        label: 'Casa',
        streetText: 'Calle Smoke 123',
        communeId: matches.first.communeId,
        point: point,
      ),
    );
    final addr = await addresses.myAddresses();
    expect(addr.single.point.lat, -33.45);
    expect(addr.single.communeName, 'Santiago');

    // Otro dueño no ve nada de lo anterior.
    final other = await _newUser('owner-f4-b');
    expect(await SupabasePetRepository(other).myPets(), isEmpty);
    expect(await SupabaseAddressRepository(other).myAddresses(), isEmpty);
  });
}
