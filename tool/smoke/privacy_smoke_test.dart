// Smoke del repositorio de privacidad (fase 11) contra Supabase local: RPC
// reales, bloqueo por eliminación (403 account_blocked) y su cancelación.
//
// Uso (con `supabase start`; no lo corre la suite normal):
//   flutter test tool/smoke/privacy_smoke_test.dart \
//     --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
//     --dart-define=SUPABASE_SERVICE_KEY=...
// Contra un stack aislado, agrega --dart-define=SUPABASE_URL=http://127.0.0.1:<puerto>
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'http://127.0.0.1:54321',
);
const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const _service = String.fromEnvironment('SUPABASE_SERVICE_KEY');
const _password = 'Felix2026';

SupabaseClient _client(String key, [AccountBlockedSignal? signal]) =>
    SupabaseClient(
      _url,
      key,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      httpClient: signal == null ? null : AccountBlockedHttpClient(signal),
    );

Future<SupabaseClient> _signIn(
  String email, [
  AccountBlockedSignal? signal,
]) async {
  final c = _client(_key, signal);
  await c.auth.signInWithPassword(email: email, password: _password);
  return c;
}

/// Crea un usuario confirmado y registrado con [role]; devuelve su correo.
Future<String> _newRegistered(AppRole role) async {
  final email =
      'smoke-priv-${role.name}-${DateTime.now().microsecondsSinceEpoch}'
      '@test.local';
  await _client(_service).auth.admin.createUser(
    AdminUserAttributes(email: email, password: _password, emailConfirm: true),
  );
  final c = await _signIn(email);
  final profiles = SupabaseProfileRepository(c);
  // QA-F11-06: el dueño exige comuna (sin ella el smoke fallaba).
  final commune = role == AppRole.owner
      ? (await c.from('communes').select('id').limit(1).single())['id'] as int
      : null;
  await profiles.completeRegistration(
    role: role,
    displayName: 'Smoke ${role.name}',
    phone: null,
    legal: await profiles.fetchLegalVersions(),
    marketingConsent: true,
    communeId: commune,
  );
  await c.dispose();
  return email;
}

void main() {
  setUpAll(() {
    if (_key.isEmpty || _service.isEmpty) {
      fail(
        'Faltan --dart-define SUPABASE_PUBLISHABLE_KEY / SUPABASE_SERVICE_KEY',
      );
    }
  });

  test('estado, consentimientos y exportación', () async {
    final c = await _signIn(await _newRegistered(AppRole.owner));
    addTearDown(c.dispose);
    final repo = SupabasePrivacyRepository(c);

    final s = await repo.status();
    expect(s.privacyVersion, isNotEmpty);
    expect(s.mustReview, isFalse, reason: 'el registro ya la mostró');
    expect(s.purposes.map((p) => p.purpose), contains('marketing'));
    expect(
      s.purposes.firstWhere((p) => p.purpose == 'marketing').granted,
      true,
    );

    final off = await repo.setConsent('marketing', granted: false);
    final m = off.purposes.firstWhere((p) => p.purpose == 'marketing');
    expect(m.granted, isFalse);
    expect(m.lastRevokedAt, isNotNull);
    await expectLater(
      repo.setConsent('no-existe', granted: true),
      throwsA(isA<PrivacyFailure>()),
    );

    final seen = await repo.recordNoticeView();
    expect(seen.mustReview, isFalse);

    final data = await repo.exportMyData();
    expect(data['format'], 'felix-export');
    expect(data['format_version'], 1);
    expect(data['subject_role'], 'owner');
  });

  test(
    'borrar: bloquea, se puede volver a entrar solo para cancelar',
    () async {
      final email = await _newRegistered(AppRole.owner);
      final c1 = await _signIn(email);
      final r = await SupabasePrivacyRepository(c1).requestDeletion();
      expect(r.status, DeletionStatus.blocked);
      expect(r.cancellable, isTrue);
      final again = await SupabasePrivacyRepository(c1).myDeletionRequest();
      expect(again?.id, r.id, reason: 'pedir dos veces da la misma');
      await c1.dispose();

      final signal = AccountBlockedSignal();
      addTearDown(signal.dispose);
      final c2 = await _signIn(email, signal);
      addTearDown(c2.dispose);
      final repo = SupabasePrivacyRepository(c2);

      await expectLater(
        SupabaseProfileRepository(c2).fetchAccount(),
        throwsA(isA<AccountBlockedException>()),
      );
      expect(signal.blocked, isTrue);
      await expectLater(repo.status(), throwsA(isA<AccountBlockedException>()));

      // Permitidas con la cuenta bloqueada.
      expect((await repo.myDeletionRequest())?.status, DeletionStatus.blocked);
      expect((await repo.exportMyData())['deletion_requests'], isNotEmpty);

      final cancelled = await repo.cancelDeletion();
      expect(cancelled.status, DeletionStatus.cancelled);
      expect(
        (await SupabaseProfileRepository(c2).fetchAccount())?.role,
        AppRole.owner,
      );
      await expectLater(repo.cancelDeletion(), throwsA(isA<PrivacyFailure>()));
    },
  );

  test('vet: sin entradas retenidas; entrada ajena → 42501', () async {
    final c = await _signIn(await _newRegistered(AppRole.vet));
    addTearDown(c.dispose);
    final repo = SupabasePrivacyRepository(c);
    expect(await repo.retainedEntries(), isEmpty);
    await expectLater(
      repo.requestRetainedEntry(
        '00000000-0000-0000-0000-000000000000',
        reason: 'Seguimiento de un paciente',
      ),
      throwsA(
        isA<PrivacyFailure>().having(
          (e) => e.message,
          'message',
          'No tienes permiso para esta acción.',
        ),
      ),
    );
  });
}
