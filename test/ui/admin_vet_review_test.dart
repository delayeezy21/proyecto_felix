import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeVetRepository vets;
  late FakeUrlOpener opener;

  setUp(() {
    auth = FakeAuthRepository(userId: 'admin');
    profiles = FakeProfileRepository(
      auth,
      accounts: {
        'admin': const Account(role: AppRole.admin, displayName: 'admin'),
      },
    );
    vets =
        FakeVetRepository(
            profile: VetProfile(
              userId: 'v1',
              displayName: 'Dra. Vera',
              status: VetStatus.pending,
              university: 'Universidad de Chile',
              graduationYear: 2015,
              titleVerificationCode: 'ABC-123',
              declarationAcceptedAt: DateTime(2026, 11, 16),
              submittedAt: DateTime(2026, 11, 16),
            ),
          )
          ..pending = [
            VetApplicationSummary(
              userId: 'v1',
              displayName: 'Dra. Vera',
              university: 'Universidad de Chile',
              submittedAt: DateTime(2026, 11, 16),
            ),
          ];
    vets.documents.add(
      VetDocument(
        id: 'd1',
        kind: VetDocumentKind.degreeCertificate,
        mime: 'application/pdf',
        sizeBytes: 10,
        uploadedAt: DateTime(2026, 11, 16),
        reviewStatus: 'pending',
        storagePath: 'v1/titulo.pdf',
      ),
    );
    opener = FakeUrlOpener();
  });

  Future<void> openReview(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, vets: vets, opener: opener),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dra. Vera'), findsOneWidget, reason: 'cola visible');
    await tester.tap(find.byKey(const Key('application-v1')));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('abre un documento con enlace temporal', (tester) async {
    await openReview(tester);
    expect(find.text('Código de verificación: ABC-123'), findsOneWidget);
    await tap(tester, 'open-degree_certificate');
    expect(vets.openedPaths, ['v1/titulo.pdf']);
    expect(opener.opened.single, contains('v1/titulo.pdf'));
  });

  testWidgets('aprobar exige los 3 chequeos obligatorios', (tester) async {
    await openReview(tester);
    FilledButton approve() =>
        tester.widget(find.byKey(const Key('review-approve')));
    expect(approve().onPressed, isNull);

    await tap(tester, 'check-name');
    await tap(tester, 'check-university');
    expect(approve().onPressed, isNull);
    await tap(tester, 'check-code');
    expect(approve().onPressed, isNotNull);

    await tap(tester, 'review-approve');
    final review = vets.reviews.single;
    expect(review.$1, 'v1');
    expect(review.$2, isTrue);
    expect(review.$4, contains('[x] El nombre del título coincide'));
    expect(review.$4, contains('[ ] Aparece en el buscador de colegiados'));
    expect(find.text('No hay solicitudes pendientes.'), findsOneWidget);
  });

  testWidgets('rechazar exige un motivo', (tester) async {
    await openReview(tester);
    await tap(tester, 'review-reject');
    await tap(tester, 'reject-confirm');
    expect(find.text('Explica el motivo'), findsOneWidget);
    expect(vets.reviews, isEmpty);

    await tester.enterText(
      find.byKey(const Key('reject-reason')),
      'El nombre no coincide con la cédula',
    );
    await tap(tester, 'reject-confirm');
    expect(vets.reviews.single.$2, isFalse);
    expect(vets.reviews.single.$3, 'El nombre no coincide con la cédula');
  });
}
