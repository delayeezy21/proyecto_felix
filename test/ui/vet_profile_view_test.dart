import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeVetRepository vets;
  late FakeDocumentPicker picker;

  setUp(() {
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
    vets = FakeVetRepository();
    picker = FakeDocumentPicker();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, vets: vets, picker: picker),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('el vet nuevo ve qué le falta y no puede enviar', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('vet-status-pending')), findsOneWidget);
    expect(find.textContaining('Te falta: Universidad'), findsOneWidget);
    final submit = tester.widget<FilledButton>(
      find.byKey(const Key('vet-submit')),
    );
    expect(submit.onPressed, isNull);
  });

  testWidgets('valida el año de titulación', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('vet-university')), 'U. Chile');
    await tester.enterText(find.byKey(const Key('vet-year')), '1800');
    await tap(tester, 'vet-save-data');
    expect(find.text('Año no válido'), findsOneWidget);
    expect(vets.profile.university, isNull);
  });

  testWidgets('rechaza archivos que no son PDF, JPG o PNG', (tester) async {
    picker.next = const PickedDocument(name: 'virus.exe', bytes: [1, 2]);
    await open(tester);
    await tap(tester, 'upload-degree_certificate');
    expect(
      find.text('Solo se aceptan archivos PDF, JPG o PNG.'),
      findsOneWidget,
    );
    expect(vets.uploads, isEmpty);
  });

  testWidgets('rechaza archivos de más de 5 MB', (tester) async {
    picker.next = PickedDocument(
      name: 'titulo.pdf',
      bytes: List.filled(maxDocumentBytes + 1, 0),
    );
    await open(tester);
    await tap(tester, 'upload-degree_certificate');
    expect(find.text('El archivo supera los 5 MB.'), findsOneWidget);
    expect(vets.uploads, isEmpty);
  });

  testWidgets('completa la solicitud y la envía a revisión', (tester) async {
    await open(tester);

    await tester.enterText(
      find.byKey(const Key('vet-university')),
      'Universidad de Chile',
    );
    await tester.enterText(find.byKey(const Key('vet-year')), '2015');
    await tester.enterText(find.byKey(const Key('vet-code')), 'ABC-123');
    await tap(tester, 'vet-save-data');
    expect(vets.profile.university, 'Universidad de Chile');
    expect(vets.profile.graduationYear, 2015);

    await tap(tester, 'chip-species-perro');
    await tap(tester, 'chip-specialties-general');
    expect(vets.species, {1});
    expect(vets.specialties, {1});

    await tap(tester, 'add-block');
    await tap(tester, 'block-save');
    expect(vets.blocks.single.weekday, 1);
    expect(find.text('Lunes · 09:00–13:00'), findsOneWidget);

    picker.next = const PickedDocument(name: 'titulo.pdf', bytes: [1, 2, 3]);
    await tap(tester, 'upload-degree_certificate');
    picker.next = const PickedDocument(name: 'cedula.jpg', bytes: [1, 2, 3]);
    await tap(tester, 'upload-id_card_front');
    expect(vets.uploads.map((u) => u.$1), [
      VetDocumentKind.degreeCertificate,
      VetDocumentKind.idCardFront,
    ]);

    expect(find.textContaining('Te falta: Declaración jurada'), findsOneWidget);
    await tap(tester, 'vet-declaration');
    expect(vets.profile.declarationAcceptedAt, isNotNull);

    await tap(tester, 'vet-submit');
    expect(vets.submits, 1);
    expect(find.byKey(const Key('vet-status-pending')), findsOneWidget);
    expect(find.text('En revisión'), findsOneWidget);
    expect(
      find.byKey(const Key('vet-university')),
      findsNothing,
      reason: 'en revisión los datos profesionales quedan bloqueados',
    );
  });

  testWidgets('un vet rechazado ve el motivo', (tester) async {
    vets.profile = const VetProfile(
      userId: 'v1',
      displayName: 'Dra. Vera',
      status: VetStatus.rejected,
      rejectionReason: 'El nombre no coincide con la cédula',
    );
    await open(tester);
    expect(find.byKey(const Key('vet-status-rejected')), findsOneWidget);
    expect(
      find.textContaining('El nombre no coincide con la cédula'),
      findsOneWidget,
    );
    expect(find.text('Reenviar a revisión'), findsOneWidget);
  });

  testWidgets('un vet aprobado administra su perfil sin tocar datos '
      'verificados', (tester) async {
    profiles.accounts['v1'] = const Account(
      role: AppRole.vet,
      displayName: 'Dra. Vera',
      vetStatus: VetStatus.approved,
    );
    vets.profile = VetProfile(
      userId: 'v1',
      displayName: 'Dra. Vera',
      status: VetStatus.approved,
      university: 'Universidad de Chile',
      graduationYear: 2015,
      submittedAt: DateTime(2026, 11, 10),
    );
    await open(tester);
    expect(find.text('Mi perfil profesional'), findsOneWidget);
    expect(find.text('Perfil verificado'), findsOneWidget);
    expect(find.text('Universidad: Universidad de Chile'), findsOneWidget);
    expect(find.byKey(const Key('vet-university')), findsNothing);
    expect(find.byKey(const Key('vet-submit')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('vet-bio')),
      'Atiendo perros y gatos',
    );
    await tap(tester, 'vet-save-data');
    expect(vets.profile.bio, 'Atiendo perros y gatos');

    await tap(tester, 'chip-species-gato');
    expect(vets.species, {2});
  });
}
