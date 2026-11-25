import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/data/services/clock.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/data/services/recovery_flag_store.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';
import 'package:proyecto_felix/ui/features/privacy/view_models/privacy_providers.dart';

import '../helpers/fakes.dart';

/// ViewModels de la fase 11 con repositorios falsos.
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakePrivacyRepository privacy;
  late FakeFileSaver saver;
  late AccountBlockedSignal signal;

  setUp(() {
    auth = FakeAuthRepository(userId: 'u1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {'u1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
    privacy = FakePrivacyRepository();
    saver = FakeFileSaver();
    signal = AccountBlockedSignal();
    addTearDown(signal.dispose);
  });

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        profileRepositoryProvider.overrideWithValue(profiles),
        privacyRepositoryProvider.overrideWithValue(privacy),
        fileSaverProvider.overrideWithValue(saver),
        accountBlockedSignalProvider.overrideWithValue(signal),
        clockProvider.overrideWithValue(ManualClock(DateTime(2026, 3, 7, 9))),
        recoveryFlagStoreProvider.overrideWithValue(FakeRecoveryFlagStore()),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('nombre del archivo de exportación', () {
    expect(
      exportFileName(DateTime(2026, 12, 2)),
      'felix-mis-datos-2026-12-02.json',
    );
  });

  test('validación del motivo de una entrada retenida', () {
    expect(validateRetainedReason('corto'), isNotNull);
    expect(validateRetainedReason('          '), isNotNull);
    expect(validateRetainedReason('Motivo suficiente'), isNull);
    expect(validateRetainedReason('x' * 501), isNotNull);
  });

  test('exportar guarda el JSON legible con la fecha del reloj', () async {
    final c = container();
    final sub = c.listen(dataExportProvider, (_, _) {});
    addTearDown(sub.close);
    final name = await c.read(dataExportProvider.notifier).export();
    expect(name, 'felix-mis-datos-2026-03-07.json');
    expect(saver.saved.single.$1, name);
    expect(jsonDecode(saver.lastJson), containsPair('format_version', 1));
    expect(saver.lastJson, contains('\n  '), reason: 'con sangría');
  });

  test('exportar con error deja el error en el estado y lo relanza', () async {
    final c = container();
    final sub = c.listen(dataExportProvider, (_, _) {});
    addTearDown(sub.close);
    privacy.nextFailure = const PrivacyFailure('falló');
    await expectLater(
      c.read(dataExportProvider.notifier).export(),
      throwsA(isA<PrivacyFailure>()),
    );
    expect(c.read(dataExportProvider).hasError, isTrue);
    expect(saver.saved, isEmpty);
  });

  test('consentimiento: un error conserva el estado anterior', () async {
    final c = container();
    final sub = c.listen(privacyStatusProvider, (_, _) {});
    addTearDown(sub.close);
    final before = await c.read(privacyStatusProvider.future);
    privacy.nextFailure = const PrivacyFailure(
      'Finalidad opcional desconocida',
    );
    await expectLater(
      c
          .read(privacyStatusProvider.notifier)
          .setConsent('marketing', granted: false),
      throwsA(isA<PrivacyFailure>()),
    );
    expect(c.read(privacyStatusProvider).value, same(before));

    await c
        .read(privacyStatusProvider.notifier)
        .setConsent('marketing', granted: false);
    expect(
      c.read(privacyStatusProvider).value!.purposes.single.granted,
      isFalse,
    );
  });

  test('ver la política la marca como revisada', () async {
    privacy.mustReview = true;
    final c = container();
    final sub = c.listen(privacyStatusProvider, (_, _) {});
    addTearDown(sub.close);
    expect((await c.read(privacyStatusProvider.future)).mustReview, isTrue);
    await c.read(privacyStatusProvider.notifier).markNoticeSeen();
    expect(c.read(privacyStatusProvider).value!.mustReview, isFalse);
    expect(privacy.noticeViews, 1);
  });

  test('pedir el borrado bloquea y cierra la sesión local', () async {
    final c = container();
    final sub = c.listen(deletionRequestProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await c.read(deletionRequestProvider.future), isNull);
    final r = await c.read(deletionRequestProvider.notifier).request();
    expect(r.status, DeletionStatus.blocked);
    expect(auth.userId, isNull);
  });

  test('el admin no puede pedir el borrado y no se cierra la sesión', () async {
    final c = container();
    final sub = c.listen(deletionRequestProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(deletionRequestProvider.future);
    privacy.nextFailure = const PrivacyFailure(
      'Esta cuenta se elimina por soporte',
    );
    await expectLater(
      c.read(deletionRequestProvider.notifier).request(),
      throwsA(isA<PrivacyFailure>()),
    );
    expect(auth.userId, 'u1');
  });

  test(
    'sesión bloqueada → cancelar limpia el aviso y recarga la cuenta',
    () async {
      profiles.blocked = true;
      privacy.deletion = DeletionRequest(
        id: 'd1',
        status: DeletionStatus.blocked,
        requestedAt: DateTime(2026, 11, 25),
        executeAfter: DateTime(2026, 12, 10),
        cancellable: true,
      );
      final c = container();
      final session = c.listen(sessionProvider, (_, _) {});
      addTearDown(session.close);
      final first = await c.read(sessionProvider.future);
      expect(first, isA<SignedIn>().having((s) => s.blocked, 'blocked', true));
      expect(signal.blocked, isTrue);

      final sub = c.listen(deletionRequestProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(deletionRequestProvider.future);
      profiles.blocked = false;
      await c.read(deletionRequestProvider.notifier).cancel();
      expect(signal.blocked, isFalse);
      final next = await c.read(sessionProvider.future);
      expect(
        next,
        isA<SignedIn>()
            .having((s) => s.blocked, 'blocked', false)
            .having((s) => s.account?.role, 'role', AppRole.owner),
      );
    },
  );

  test('cerrar sesión apaga el aviso de bloqueo', () async {
    final c = container();
    signal.report();
    await c.read(authControllerProvider.notifier).signOut();
    expect(signal.blocked, isFalse);
  });
}
