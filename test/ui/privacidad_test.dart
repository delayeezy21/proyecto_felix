import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:proyecto_felix/ui/features/privacy/views/account_blocked_view.dart';
import 'package:proyecto_felix/ui/features/privacy/views/privacy_policy_view.dart';
import 'package:proyecto_felix/ui/features/privacy/views/privacy_view.dart';

import '../helpers/fakes.dart';

const _ana = Account(role: AppRole.owner, displayName: 'Ana');

DeletionRequest _blockedRequest({bool cancellable = true}) => DeletionRequest(
  id: 'd1',
  status: cancellable ? DeletionStatus.blocked : DeletionStatus.executing,
  requestedAt: DateTime(2026, 11, 25, 14, 5),
  executeAfter: DateTime(2026, 12, 10, 14, 5),
  cancellable: cancellable,
);

/// Fase 11 (HU8.1 a HU8.5): privacidad y datos, cuenta bloqueada y aviso de
/// política nueva, con repositorios falsos.
void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakePrivacyRepository privacy;
  late FakeFileSaver saver;

  setUp(() {
    auth = FakeAuthRepository(userId: 'u1');
    profiles = FakeProfileRepository(auth, accounts: {'u1': _ana});
    privacy = FakePrivacyRepository();
    saver = FakeFileSaver();
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    AccountBlockedSignal? signal,
    Size? size,
    double textScale = 1,
  }) async {
    if (size != null) {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
    }
    await tester.pumpWidget(
      testApp(
        auth: auth,
        profiles: profiles,
        privacy: privacy,
        fileSaver: saver,
        blockedSignal: signal,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Las listas son perezosas: si el elemento aún no se construye, desplaza
  /// la lista vertical que lo contenga hasta encontrarlo.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    final scrollables = find.byType(Scrollable).hitTestable();
    for (var i = 0; finder.evaluate().isEmpty; i++) {
      if (i >= scrollables.evaluate().length) break;
      final s = scrollables.at(i);
      if (tester.state<ScrollableState>(s).position.axis != Axis.vertical) {
        continue;
      }
      try {
        await tester.scrollUntilVisible(finder, 150, scrollable: s);
      } on Object {
        // No estaba en esta lista: prueba la siguiente.
      }
    }
    await tester.ensureVisible(finder);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await reveal(tester, finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openPrivacyAsOwner(WidgetTester tester) async {
    await tapKey(tester, 'owner-profile');
    await tapKey(tester, 'profile-privacy');
    expect(find.byType(PrivacyView), findsOneWidget);
  }

  group('privacidad y datos', () {
    testWidgets('descarga mis datos como JSON con la fecha del día', (
      tester,
    ) async {
      await pumpApp(tester);
      await openPrivacyAsOwner(tester);
      await tapKey(tester, 'privacy-export');

      expect(privacy.exportCalls, 1);
      // ManualClock: 24 de noviembre de 2026.
      expect(saver.saved.single.$1, 'felix-mis-datos-2026-11-24.json');
      final data = jsonDecode(saver.lastJson) as Map<String, dynamic>;
      expect(data['format'], 'felix-export');
      expect(find.byKey(const Key('export-done')), findsOneWidget);
    });

    testWidgets('si cancela el diálogo de guardar no avisa nada', (
      tester,
    ) async {
      saver.result = false;
      await pumpApp(tester);
      await openPrivacyAsOwner(tester);
      await tapKey(tester, 'privacy-export');
      expect(find.byKey(const Key('export-done')), findsNothing);
      expect(find.byKey(const Key('snack-error')), findsNothing);
    });

    testWidgets('un error al exportar se muestra legible', (tester) async {
      await pumpApp(tester);
      await openPrivacyAsOwner(tester);
      privacy.nextFailure = const PrivacyFailure('Sin conexión al servidor.');
      await tapKey(tester, 'privacy-export');
      expect(find.text('Sin conexión al servidor.'), findsOneWidget);
    });

    testWidgets('consentimientos: retirar pide confirmación y queda '
        'registrado', (tester) async {
      await pumpApp(tester);
      await openPrivacyAsOwner(tester);
      expect(find.textContaining('no por consentimiento'), findsOneWidget);
      expect(find.textContaining('Otorgado el 2 de noviembre'), findsOneWidget);

      // Cancelar el diálogo no cambia nada.
      await tapKey(tester, 'consent-marketing');
      expect(find.text('¿Retirar el consentimiento?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(privacy.consentCalls, isEmpty);

      await tapKey(tester, 'consent-marketing');
      await tester.tap(find.byKey(const Key('consent-revoke-confirm')));
      await tester.pumpAndSettle();
      expect(privacy.consentCalls, [('marketing', false)]);
      expect(
        find.textContaining('Retirado el 25 de noviembre'),
        findsOneWidget,
      );

      // Otorgar no pide confirmación.
      await tapKey(tester, 'consent-marketing');
      expect(privacy.consentCalls.last, ('marketing', true));
    });

    testWidgets('borrar mi cuenta exige escribir BORRAR y cierra la sesión', (
      tester,
    ) async {
      await pumpApp(tester);
      await openPrivacyAsOwner(tester);
      await tapKey(tester, 'privacy-delete');

      expect(find.textContaining('15 días'), findsWidgets);
      expect(find.textContaining('5 años'), findsOneWidget);
      expect(find.textContaining('anonimizados'), findsOneWidget);
      FilledButton confirm() =>
          tester.widget<FilledButton>(find.byKey(const Key('delete-confirm')));
      expect(confirm().onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('delete-confirm-word')),
        'borrar',
      );
      await tester.pump();
      expect(confirm().onPressed, isNull, reason: 'distingue mayúsculas');

      await tester.enterText(
        find.byKey(const Key('delete-confirm-word')),
        'BORRAR',
      );
      await tester.pump();
      expect(confirm().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await tester.pumpAndSettle();

      expect(privacy.requestCalls, 1);
      expect(auth.userId, isNull, reason: 'cierra la sesión local');
      expect(find.byKey(const Key('delete-requested')), findsOneWidget);
      expect(find.textContaining('10 de diciembre de 2026'), findsOneWidget);
    });

    testWidgets('cancelar el diálogo de borrado no pide nada', (tester) async {
      await pumpApp(tester);
      await openPrivacyAsOwner(tester);
      await tapKey(tester, 'privacy-delete');
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(privacy.requestCalls, 0);
      expect(auth.userId, 'u1');
    });

    testWidgets('el vet en revisión también la abre; sin entradas retenidas '
        'no muestra la sección', (tester) async {
      auth = FakeAuthRepository(userId: 'v1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'v1': const Account(
            role: AppRole.vet,
            displayName: 'Dra. Vera',
            vetStatus: VetStatus.pending,
          ),
        },
      );
      await pumpApp(tester);
      await tapKey(tester, 'vet-privacy');
      expect(find.byType(PrivacyView), findsOneWidget);
      await reveal(tester, find.byKey(const Key('privacy-delete')));
      expect(find.byKey(const Key('privacy-delete')), findsOneWidget);
      expect(find.byKey(const Key('retained-section')), findsNothing);
    });

    testWidgets('vet: entrada retenida exige motivo y muestra la entrada '
        'redactada', (tester) async {
      auth = FakeAuthRepository(userId: 'v1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'v1': const Account(
            role: AppRole.vet,
            displayName: 'Dra. Vera',
            vetStatus: VetStatus.pending,
          ),
        },
      );
      privacy.retained = [
        RetainedEntry(
          id: 'e1',
          createdAt: DateTime(2026, 1, 10),
          kind: 'consultation',
          species: 'Perro',
          retainUntil: DateTime(2031, 11, 25),
        ),
      ];
      await pumpApp(tester);
      await tapKey(tester, 'vet-privacy');
      await reveal(tester, find.byKey(const Key('retained-section')));
      expect(find.byKey(const Key('retained-section')), findsOneWidget);
      expect(find.textContaining('25 de noviembre de 2031'), findsOneWidget);

      await tapKey(tester, 'retained-open-e1');
      await tester.enterText(find.byKey(const Key('retained-reason')), 'corto');
      await tester.tap(find.byKey(const Key('retained-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('al menos 10 caracteres'), findsOneWidget);
      expect(privacy.retainedRequests, isEmpty);

      await tester.enterText(
        find.byKey(const Key('retained-reason')),
        'Seguimiento de un control anterior',
      );
      await tester.tap(find.byKey(const Key('retained-submit')));
      await tester.pumpAndSettle();
      expect(privacy.retainedRequests.single, (
        'e1',
        'Seguimiento de un control anterior',
      ));
      expect(find.byKey(const Key('retained-detail')), findsOneWidget);
      expect(find.text('Paciente [redactado] sin hallazgos.'), findsOneWidget);
    });

    testWidgets('fundación: entra desde su inicio', (tester) async {
      auth = FakeAuthRepository(userId: 'f1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'f1': const Account(role: AppRole.foundation, displayName: 'f1'),
        },
      );
      await pumpApp(tester);
      await tapKey(tester, 'foundation-privacy');
      expect(find.byType(PrivacyView), findsOneWidget);
      expect(find.textContaining('membresía'), findsNothing);
      await tapKey(tester, 'privacy-delete');
      expect(find.textContaining('membresía'), findsOneWidget);
    });
  });

  group('cuenta en proceso de borrado', () {
    testWidgets('al iniciar sesión bloqueado muestra la fecha; cancelar '
        'vuelve al inicio', (tester) async {
      profiles.blocked = true;
      privacy.deletion = _blockedRequest();
      await pumpApp(tester);

      expect(find.byType(AccountBlockedView), findsOneWidget);
      expect(
        find.textContaining('10 de diciembre de 2026, 14:05'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('blocked-export')), findsOneWidget);
      expect(find.byKey(const Key('blocked-sign-out')), findsOneWidget);

      // El servidor deja de bloquear al cancelar.
      profiles.blocked = false;
      await tapKey(tester, 'blocked-cancel');
      expect(privacy.cancelCalls, 1);
      expect(find.byType(AccountBlockedView), findsNothing);
      expect(find.byKey(const Key('owner-profile')), findsOneWidget);
    });

    testWidgets('sin "cancellable" no ofrece cancelar, pero sí exportar', (
      tester,
    ) async {
      profiles.blocked = true;
      privacy.deletion = _blockedRequest(cancellable: false);
      await pumpApp(tester);

      expect(find.byType(AccountBlockedView), findsOneWidget);
      expect(find.byKey(const Key('blocked-cancel')), findsNothing);
      expect(find.text('El borrado está en curso'), findsOneWidget);
      await tapKey(tester, 'blocked-export');
      expect(saver.saved, hasLength(1));
    });

    testWidgets('cerrar sesión desde la pantalla bloqueada', (tester) async {
      profiles.blocked = true;
      privacy.deletion = _blockedRequest();
      await pumpApp(tester);
      await tapKey(tester, 'blocked-sign-out');
      expect(auth.userId, isNull);
      expect(find.byType(AccountBlockedView), findsNothing);
    });

    testWidgets('una llamada con account_blocked lleva a la pantalla de '
        'borrado desde cualquier parte', (tester) async {
      final signal = AccountBlockedSignal();
      addTearDown(signal.dispose);
      await pumpApp(tester, signal: signal);
      expect(find.byKey(const Key('owner-profile')), findsOneWidget);

      privacy.deletion = _blockedRequest();
      signal.report();
      await tester.pumpAndSettle();
      expect(find.byType(AccountBlockedView), findsOneWidget);
      expect(find.byKey(const Key('blocked-cancel')), findsOneWidget);
    });

    testWidgets('si ya no hay borrado pendiente ofrece volver al inicio', (
      tester,
    ) async {
      final signal = AccountBlockedSignal();
      addTearDown(signal.dispose);
      await pumpApp(tester, signal: signal);
      signal.report();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('blocked-none')), findsOneWidget);
      await tapKey(tester, 'blocked-resume');
      expect(signal.blocked, isFalse);
      expect(find.byKey(const Key('owner-profile')), findsOneWidget);
    });
  });

  group('aviso de política nueva', () {
    testWidgets('lleva a la política, registra la lectura y desaparece', (
      tester,
    ) async {
      privacy
        ..mustReview = true
        ..privacyVersion = 'p-2';
      await pumpApp(tester);
      expect(find.byKey(const Key('privacy-notice')), findsOneWidget);
      expect(find.textContaining('versión p-2'), findsOneWidget);

      await tapKey(tester, 'privacy-notice-review');
      expect(find.byType(PrivacyPolicyView), findsOneWidget);
      expect(find.text('Versión vigente: p-2'), findsOneWidget);
      expect(privacy.noticeViews, 1);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('privacy-notice')), findsNothing);
    });

    testWidgets('"Más tarde" lo oculta sin bloquear el uso', (tester) async {
      privacy.mustReview = true;
      await pumpApp(tester);
      await tapKey(tester, 'privacy-notice-later');
      expect(find.byKey(const Key('privacy-notice')), findsNothing);
      expect(privacy.noticeViews, 0);
    });

    testWidgets('sin cambios no hay aviso', (tester) async {
      await pumpApp(tester);
      expect(find.byKey(const Key('privacy-notice')), findsNothing);
    });

    testWidgets('una finalidad opcional nueva se pide desde el aviso', (
      tester,
    ) async {
      privacy.purposes = [
        const ConsentPurpose(
          purpose: 'marketing',
          description: 'Novedades',
          granted: false,
          ask: true,
        ),
      ];
      await pumpApp(tester);
      expect(find.textContaining('nueva finalidad'), findsOneWidget);
      await tapKey(tester, 'privacy-notice-review');
      expect(find.byType(PrivacyView), findsOneWidget);
      expect(find.textContaining('aún no la respondes'), findsOneWidget);
    });
  });

  group('360 px con texto grande', () {
    const phone = Size(360, 740);

    testWidgets('privacidad y diálogo de borrado sin desbordes', (
      tester,
    ) async {
      privacy.mustReview = true;
      await pumpApp(tester, size: phone, textScale: 1.5);
      await openPrivacyAsOwner(tester);
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('privacy-delete')),
        200,
        scrollable: list,
      );
      await tapKey(tester, 'privacy-delete');
      expect(find.byKey(const Key('delete-confirm')), findsOneWidget);
    });

    testWidgets('pantalla bloqueada sin desbordes', (tester) async {
      profiles.blocked = true;
      privacy.deletion = _blockedRequest();
      await pumpApp(tester, size: phone, textScale: 1.5);
      expect(find.byType(AccountBlockedView), findsOneWidget);
    });

    testWidgets('aviso de política en el inicio sin desbordes', (tester) async {
      privacy.mustReview = true;
      await pumpApp(tester, size: phone, textScale: 1.5);
      expect(find.byKey(const Key('privacy-notice')), findsOneWidget);
    });

    testWidgets('privacidad cumple las guías de accesibilidad', (tester) async {
      await pumpApp(tester, size: const Size(360, 3000));
      await openPrivacyAsOwner(tester);
      final handle = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });
}
