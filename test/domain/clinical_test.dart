import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/clinical_repository.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';

ClinicalEntry entry(
  String id, {
  String? supersedes,
  String? supersededBy,
  int minute = 0,
  EntryKind kind = EntryKind.diagnosis,
}) => ClinicalEntry(
  id: id,
  kind: kind,
  title: 'Entrada $id',
  byOwner: false,
  createdAt: DateTime(2026, 11, 18, 10, minute),
  supersedesId: supersedes,
  supersededBy: supersededBy,
);

void main() {
  group('versionado de correcciones', () {
    test('una entrada sin correcciones queda sola y vigente', () {
      final h = entryHistories([entry('a')]);
      expect(h, hasLength(1));
      expect(h.single.current.id, 'a');
      expect(h.single.wasCorrected, isFalse);
    });

    test(
      'una cadena a → b → c muestra c vigente con b y a como anteriores',
      () {
        final h = entryHistories([
          entry('a', supersededBy: 'b'),
          entry('c', supersedes: 'b', minute: 2),
          entry('b', supersedes: 'a', supersededBy: 'c', minute: 1),
        ]);
        expect(h, hasLength(1));
        expect(h.single.current.id, 'c');
        expect(h.single.previous.map((e) => e.id), ['b', 'a']);
        expect(h.single.wasCorrected, isTrue);
      },
    );

    test('las vigentes se ordenan por la fecha de su última versión', () {
      final h = entryHistories([
        entry('x', minute: 5),
        entry('a'),
        entry('a2', supersedes: 'a', minute: 9),
      ]);
      expect(h.map((e) => e.current.id), ['a2', 'x']);
    });

    test('si la versión anterior no llegó, la corrección inicia su cadena', () {
      final h = entryHistories([entry('b', supersedes: 'perdida')]);
      expect(h.single.current.id, 'b');
      expect(h.single.previous, isEmpty);
    });

    test('un ciclo malformado no cuelga el cálculo', () {
      final h = entryHistories([
        entry('a', supersedes: 'b'),
        entry('b', supersedes: 'a'),
        entry('c', supersedes: 'a', minute: 3),
      ]);
      expect(h.map((e) => e.current.id), ['c']);
      expect(h.single.previous.length, lessThanOrEqualTo(2));
    });

    test('las vacunas de la ficha son solo las vigentes', () {
      final vaccine = VaccineData(name: 'Óctuple', appliedOn: DateTime(2026));
      final record = PetRecord(
        pet: const RecordPet(id: 'p', name: 'Firulais'),
        isOwnerView: true,
        canWrite: true,
        entries: [
          ClinicalEntry(
            id: 'v1',
            kind: EntryKind.vaccine,
            title: 'Óctuple',
            byOwner: false,
            createdAt: DateTime(2026),
            supersededBy: 'v2',
            vaccine: vaccine,
          ),
          ClinicalEntry(
            id: 'v2',
            kind: EntryKind.vaccine,
            title: 'Óctuple (lote corregido)',
            byOwner: false,
            createdAt: DateTime(2026, 1, 2),
            supersedesId: 'v1',
            vaccine: vaccine,
          ),
        ],
      );
      expect(record.vaccines.map((e) => e.id), ['v2']);
    });
  });

  group('JSON de get_pet_record', () {
    test('lee entradas, vacuna, adjuntos, reemplazos y acceso del vet', () {
      final r = PetRecord.fromJson(const {
        'viewer': 'vet',
        'can_write': true,
        'pet': {'id': 'p', 'name': 'Luna', 'species_name': 'Gato'},
        'access': {'via': 'owner_grant', 'until': '2026-12-01T03:00:00Z'},
        'grants': null,
        'entries': [
          {
            'id': 'e1',
            'kind': 'vaccine',
            'title': 'Antirrábica',
            'author_role': 'vet',
            'author_name': 'Dra. Vera',
            'mine': true,
            'created_at': '2026-11-18T13:00:00Z',
            'supersedes_id': null,
            'superseded_by': 'e2',
            'vaccine': {
              'vaccine_name': 'Antirrábica',
              'lot': 'L1',
              'applied_on': '2026-11-18',
              'next_due': '2027-11-18',
            },
            'attachments': [
              {
                'id': 'a1',
                'file_name': 'receta.pdf',
                'mime': 'application/pdf',
                'size_bytes': 10,
              },
            ],
          },
        ],
      });
      expect(r.isOwnerView, isFalse);
      expect(r.accessVia, 'owner_grant');
      expect(r.accessUntil, isNotNull);
      final e = r.entries.single;
      expect(e.kind, EntryKind.vaccine);
      expect(e.isCurrent, isFalse);
      expect(e.vaccine!.nextDue, DateTime(2027, 11, 18));
      expect(e.attachments.single.fileName, 'receta.pdf');
      expect(r.grants, isEmpty);
    });
  });

  group('validación de entradas', () {
    EntryDraft draft({
      String title = 'Control',
      EntryKind kind = EntryKind.note,
      VaccineData? vaccine,
    }) => EntryDraft(petId: 'p', kind: kind, title: title, vaccine: vaccine);

    test('exige título de hasta 120 caracteres', () {
      expect(validateEntryDraft(draft(title: '  ')), isNotNull);
      expect(validateEntryDraft(draft(title: 'x' * 121)), isNotNull);
      expect(validateEntryDraft(draft()), isNull);
    });

    test('una vacuna exige nombre y próxima dosis posterior', () {
      expect(validateEntryDraft(draft(kind: EntryKind.vaccine)), isNotNull);
      final applied = DateTime(2026, 11, 18);
      expect(
        validateEntryDraft(
          draft(
            kind: EntryKind.vaccine,
            vaccine: VaccineData(
              name: 'Óctuple',
              appliedOn: applied,
              nextDue: applied,
            ),
          ),
        ),
        isNotNull,
      );
      expect(
        validateEntryDraft(
          draft(
            kind: EntryKind.vaccine,
            vaccine: VaccineData(
              name: 'Óctuple',
              appliedOn: applied,
              nextDue: DateTime(2027, 11, 18),
            ),
          ),
        ),
        isNull,
      );
    });

    test('el nombre del adjunto no lleva rutas ni excede 120 caracteres', () {
      expect(attachmentDisplayName(r'C:\fotos\rx.png'), 'rx.png');
      expect(attachmentDisplayName('a/b/receta.pdf'), 'receta.pdf');
      expect(attachmentDisplayName('${'x' * 200}.pdf').length, 120);
      expect(attachmentDisplayName(' '), 'adjunto');
    });
  });
}
