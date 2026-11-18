import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/clinical_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/pricing.dart' show VisitMode;
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

import '../helpers/fakes.dart';

void main() {
  void bigView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(800, 2600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  ClinicalEntry e(
    String id,
    String title, {
    EntryKind kind = EntryKind.diagnosis,
    bool byOwner = false,
    bool mine = false,
    String? supersedes,
    int minute = 0,
    VaccineData? vaccine,
    List<EntryAttachment> attachments = const [],
  }) => ClinicalEntry(
    id: id,
    kind: kind,
    title: title,
    byOwner: byOwner,
    authorName: byOwner ? null : 'Dra. Vera',
    mine: mine,
    createdAt: DateTime(2026, 11, 18, 10, minute),
    supersedesId: supersedes,
    vaccine: vaccine,
    attachments: attachments,
  );

  group('ficha del dueño', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakePetRepository pets;
    late FakeVisitRepository visits;
    late FakeClinicalRepository clinical;

    setUp(() {
      auth = FakeAuthRepository(userId: 'o1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'o1': const Account(role: AppRole.owner, displayName: 'Ana'),
        },
      );
      pets = FakePetRepository(
        pets: [
          const Pet(
            id: 'p1',
            name: 'Firulais',
            speciesId: 1,
            speciesName: 'Perro',
            sex: PetSex.male,
            sterilized: true,
            active: true,
          ),
        ],
      );
      visits = FakeVisitRepository()
        ..visits = [
          const Visit(
            id: 'vis1',
            isOwnerView: true,
            status: VisitStatus.completed,
            mode: VisitMode.scheduled,
            petId: 'p1',
            vetId: 'v9',
            vetName: 'Dra. Vera',
            closedBySystem: true,
          ),
        ];
      clinical =
          FakeClinicalRepository(
              entries: [
                e('d1', 'Otitis', minute: 1),
                e('d2', 'Otitis externa', supersedes: 'd1', minute: 2),
                e(
                  'v1',
                  'Antirrábica',
                  kind: EntryKind.vaccine,
                  vaccine: VaccineData(
                    name: 'Antirrábica',
                    appliedOn: DateTime(2026, 11, 18),
                    nextDue: DateTime(2027, 11, 18),
                  ),
                  attachments: const [
                    EntryAttachment(
                      id: 'att1',
                      fileName: 'certificado.pdf',
                      mime: 'application/pdf',
                      sizeBytes: 100,
                    ),
                  ],
                ),
                e(
                  'n1',
                  'Come poco',
                  kind: EntryKind.note,
                  byOwner: true,
                  mine: true,
                ),
              ],
            )
            ..grants = [
              RecordGrant(
                id: 'g1',
                vetName: 'Dr. Segunda Opinión',
                fromVisit: false,
                active: true,
                startsAt: DateTime(2026, 11, 18),
                expiresAt: DateTime(2026, 11, 25),
              ),
              RecordGrant(
                id: 'g2',
                vetName: 'Dra. Vera',
                fromVisit: true,
                active: true,
                startsAt: DateTime(2026, 11, 17),
                expiresAt: DateTime(2026, 12, 18),
              ),
            ]
            ..log = [
              AccessLogItem(
                at: DateTime(2026, 11, 18, 11),
                action: 'view',
                via: 'visit',
                actorName: 'Dra. Vera',
              ),
              AccessLogItem(
                at: DateTime(2026, 11, 18, 12),
                action: 'grant',
                via: 'owner',
                actorName: 'Tú',
              ),
            ];
    });

    Future<FakeUrlOpener> openRecord(WidgetTester tester) async {
      bigView(tester);
      final opener = FakeUrlOpener();
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          pets: pets,
          visits: visits,
          clinical: clinical,
          opener: opener,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pet-record-p1')));
      await tester.pumpAndSettle();
      return opener;
    }

    testWidgets('muestra entradas vigentes, versiones anteriores, vacunas y '
        'adjuntos', (tester) async {
      final opener = await openRecord(tester);
      expect(find.text('Ficha de Firulais'), findsOneWidget);
      expect(find.byKey(const Key('record-entry-d2')), findsOneWidget);
      // La versión anterior no se muestra como vigente: va en el historial.
      expect(find.byKey(const Key('record-entry-d1')), findsNothing);
      expect(find.text('Corregida · 1 versión anterior'), findsOneWidget);
      await tester.tap(find.byKey(const Key('record-history-d2')));
      await tester.pumpAndSettle();
      expect(find.text('Otitis'), findsOneWidget);
      expect(find.text('Reemplazada'), findsOneWidget);

      expect(find.byKey(const Key('record-vaccine-v1')), findsOneWidget);
      expect(find.textContaining('próxima dosis: 18-11-2027'), findsOneWidget);
      expect(find.textContaining('Aportado por el dueño'), findsOneWidget);
      // Solo el autor corrige: el dueño, su nota; no el diagnóstico del vet.
      expect(find.byKey(const Key('record-correct-n1')), findsOneWidget);
      expect(find.byKey(const Key('record-correct-d2')), findsNothing);

      // Adjunto: URL firmada y un toque nuevo para abrirla (Safari de iPhone).
      await tester.tap(find.byKey(const Key('record-attachment-att1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('vence en 60 segundos'), findsOneWidget);
      await tester.tap(find.byKey(const Key('attachment-open')));
      await tester.pumpAndSettle();
      expect(opener.opened.single, contains('/storage/v1/object/sign/att1'));
    });

    testWidgets('el dueño agrega una nota y corrige la suya', (tester) async {
      await openRecord(tester);
      await tester.tap(find.byKey(const Key('record-add')));
      await tester.pumpAndSettle();
      // El dueño solo escribe notas: no elige tipo.
      expect(find.byKey(const Key('entry-kind')), findsNothing);
      await tester.enterText(find.byKey(const Key('entry-title')), 'Vomitó');
      await tester.tap(find.byKey(const Key('entry-save')));
      await tester.pumpAndSettle();
      expect(clinical.drafts.single.kind, EntryKind.note);
      expect(clinical.drafts.single.visitId, isNull);

      await tester.tap(find.byKey(const Key('record-correct-n1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('se guardará una versión nueva'), findsOne);
      await tester.enterText(
        find.byKey(const Key('entry-title')),
        'Come poco desde el lunes',
      );
      await tester.tap(find.byKey(const Key('entry-save')));
      await tester.pumpAndSettle();
      expect(clinical.drafts.last.supersedesId, 'n1');
      expect(find.byKey(const Key('record-entry-n1')), findsNothing);
    });

    testWidgets('gestiona autorizaciones: otorga y revoca', (tester) async {
      await openRecord(tester);
      expect(find.text('Dr. Segunda Opinión'), findsOneWidget);
      // El acceso de una visita no lo revoca el dueño (vence solo).
      expect(find.byKey(const Key('grant-revoke-g2')), findsNothing);
      await tester.tap(find.byKey(const Key('grant-revoke-g1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grant-revoke-confirm')));
      await tester.pumpAndSettle();
      expect(clinical.revoked, ['g1']);
      expect(find.byKey(const Key('grant-revoke-g1')), findsNothing);
      expect(find.text('Accesos terminados (1)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('grant-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grant-vet')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dra. Vera').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('grant-save')));
      await tester.pumpAndSettle();
      expect(clinical.granted.single.$2, 'v9');
      final days = clinical.granted.single.$3.difference(DateTime.now()).inDays;
      expect(days, inInclusiveRange(6, 7));
    });

    testWidgets('"Quién vio mi ficha" lista lecturas y autorizaciones', (
      tester,
    ) async {
      await openRecord(tester);
      await tester.tap(find.byKey(const Key('record-log')));
      await tester.pumpAndSettle();
      expect(find.text('Quién vio mi ficha'), findsOneWidget);
      expect(find.text('Dra. Vera vio la ficha'), findsOneWidget);
      expect(find.textContaining('por una visita'), findsOneWidget);
      expect(find.text('Tú autorizó a un veterinario'), findsOneWidget);
    });
  });

  group('ficha del vet', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeVisitRepository visits;
    late FakeVetRepository vets;
    late FakeClinicalRepository clinical;

    Visit visit({
      bool access = true,
      bool writable = true,
      bool bySystem = false,
    }) => Visit(
      id: 'vis1',
      isOwnerView: false,
      status: VisitStatus.completed,
      mode: VisitMode.scheduled,
      scheduledAt: DateTime(2026, 11, 18, 10),
      petId: 'p1',
      petName: 'Firulais',
      recordAccess: access,
      recordWritable: writable,
      recordUntil: DateTime(2026, 12, 18, 10),
      closedBySystem: bySystem,
    );

    setUp(() {
      auth = FakeAuthRepository(userId: 'v1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'v1': const Account(
            role: AppRole.vet,
            displayName: 'Dra. Vera',
            vetStatus: VetStatus.approved,
          ),
        },
      );
      visits = FakeVisitRepository();
      vets = FakeVetRepository(
        profile: const VetProfile(
          userId: 'v1',
          displayName: 'Dra. Vera',
          status: VetStatus.approved,
        ),
      );
      clinical = FakeClinicalRepository(
        ownerView: false,
        entries: [e('d1', 'Otitis', mine: true)],
      );
    });

    Future<FakeDocumentPicker> openVisits(WidgetTester tester) async {
      bigView(tester);
      final picker = FakeDocumentPicker();
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          vets: vets,
          visits: visits,
          clinical: clinical,
          picker: picker,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vet-open-visits')));
      await tester.pumpAndSettle();
      return picker;
    }

    testWidgets('desde la visita lee la ficha (registrada), agrega una '
        'vacuna, corrige y adjunta', (tester) async {
      visits.visits = [visit(bySystem: true)];
      final picker = await openVisits(tester);
      // O-6: la visita cerrada por el sistema se distingue.
      expect(find.byKey(const Key('vet-visit-system-vis1')), findsOneWidget);
      expect(find.textContaining('Acceso a la ficha hasta el'), findsOneWidget);
      await tester.tap(find.byKey(const Key('vet-record-vis1')));
      await tester.pumpAndSettle();
      expect(clinical.reads.single, ('p1', 'vis1'));
      expect(
        find.textContaining('Cada lectura queda registrada'),
        findsOneWidget,
      );
      expect(find.textContaining('Microchip 985112000000001'), findsOneWidget);

      await tester.tap(find.byKey(const Key('record-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('entry-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vacuna').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('entry-title')), 'Óctuple');
      await tester.tap(find.byKey(const Key('entry-save')));
      await tester.pumpAndSettle();
      expect(find.text('Indica el nombre de la vacuna.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('entry-vaccine')), 'Óctuple');
      await tester.tap(find.byKey(const Key('entry-save')));
      await tester.pumpAndSettle();
      final d = clinical.drafts.single;
      expect(d.kind, EntryKind.vaccine);
      expect(d.visitId, 'vis1');
      expect(d.vaccine!.name, 'Óctuple');

      await tester.tap(find.byKey(const Key('record-correct-d1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('entry-title')),
        'Otitis externa',
      );
      await tester.tap(find.byKey(const Key('entry-save')));
      await tester.pumpAndSettle();
      expect(clinical.drafts.last.supersedesId, 'd1');
      expect(clinical.drafts.last.kind, EntryKind.diagnosis);

      picker.next = const PickedDocument(name: 'rx.pdf', bytes: [1, 2, 3]);
      final current = clinical.entries.last.id;
      await tester.tap(find.byKey(Key('record-attach-$current')));
      await tester.pumpAndSettle();
      expect(clinical.uploads.single.$1, current);
    });

    testWidgets('con autorización del dueño solo lee', (tester) async {
      visits.visits = [visit(writable: false)];
      clinical.canWrite = false;
      await openVisits(tester);
      expect(find.text('Ver ficha'), findsOneWidget);
      await tester.tap(find.byKey(const Key('vet-record-vis1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('record-add')), findsNothing);
      expect(find.byKey(const Key('record-correct-d1')), findsNothing);
      expect(find.textContaining('Solo lectura.'), findsOneWidget);
    });

    testWidgets('sin acceso vigente no hay botón ni ficha', (tester) async {
      visits.visits = [visit(access: false, writable: false)];
      await openVisits(tester);
      expect(find.byKey(const Key('vet-record-vis1')), findsNothing);
    });

    testWidgets('si el servidor niega la lectura, se informa', (tester) async {
      visits.visits = [visit()];
      clinical.recordFailure = const ClinicalFailure(
        'La ficha no existe o no tienes acceso',
      );
      await openVisits(tester);
      await tester.tap(find.byKey(const Key('vet-record-vis1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('record-error')), findsOneWidget);
      expect(
        find.text('La ficha no existe o no tienes acceso'),
        findsOneWidget,
      );
    });
  });
}
