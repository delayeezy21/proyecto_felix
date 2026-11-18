import 'package:proyecto_felix/data/repositories/clinical_repository.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';
import 'package:proyecto_felix/domain/models/vet.dart' show PickedDocument;

/// Ficha en memoria. Imita al servidor en lo que la UI necesita: solo
/// inserción (una corrección agrega una entrada con `supersedesId`) y
/// revocación de autorizaciones del dueño.
class FakeClinicalRepository implements ClinicalRepository {
  new({
    this.ownerView = true,
    this.canWrite = true,
    List<ClinicalEntry>? entries,
  }) : entries = entries ?? [];

  bool ownerView;
  bool canWrite;
  List<ClinicalEntry> entries;
  List<RecordGrant> grants = [];
  List<AccessLogItem> log = [];
  ClinicalFailure? recordFailure;
  final reads = <(String, String?)>[];
  final drafts = <EntryDraft>[];
  final uploads = <(String, PickedDocument)>[];
  final granted = <(String, String, DateTime)>[];
  final revoked = <String>[];
  int _seq = 0;

  @override
  Future<PetRecord> record(String petId, {String? visitId}) async {
    reads.add((petId, visitId));
    final f = recordFailure;
    if (f != null) throw f;
    return PetRecord(
      pet: RecordPet(
        id: petId,
        name: 'Firulais',
        speciesName: 'Perro',
        microchip: '985112000000001',
      ),
      isOwnerView: ownerView,
      canWrite: canWrite,
      entries: [
        for (final e in entries)
          ClinicalEntry(
            id: e.id,
            kind: e.kind,
            title: e.title,
            body: e.body,
            byOwner: e.byOwner,
            authorName: e.authorName,
            mine: e.mine,
            createdAt: e.createdAt,
            supersedesId: e.supersedesId,
            supersededBy: entries
                .where((c) => c.supersedesId == e.id)
                .map((c) => c.id)
                .firstOrNull,
            vaccine: e.vaccine,
            attachments: e.attachments,
          ),
      ],
      grants: ownerView ? grants : const [],
      accessVia: ownerView ? null : 'visit',
    );
  }

  @override
  Future<String> addEntry(EntryDraft draft) async {
    drafts.add(draft);
    final id = 'new${++_seq}';
    entries.add(
      ClinicalEntry(
        id: id,
        kind: draft.kind,
        title: draft.title,
        body: draft.body,
        byOwner: ownerView,
        authorName: ownerView ? null : 'Dra. Vera',
        mine: true,
        createdAt: DateTime(2026, 11, 18, 12).add(Duration(minutes: _seq)),
        supersedesId: draft.supersedesId,
        vaccine: draft.vaccine,
      ),
    );
    return id;
  }

  @override
  Future<void> attach({
    required String petId,
    required String entryId,
    required PickedDocument file,
  }) async => uploads.add((entryId, file));

  @override
  Future<Uri> attachmentUrl(String attachmentId) async =>
      Uri.parse('http://127.0.0.1:54321/storage/v1/object/sign/$attachmentId');

  @override
  Future<List<AccessLogItem>> accessLog(String petId) async => log;

  @override
  Future<void> grantAccess({
    required String petId,
    required String vetId,
    required DateTime until,
  }) async => granted.add((petId, vetId, until));

  @override
  Future<void> revokeGrant(String grantId) async {
    revoked.add(grantId);
    grants = [
      for (final g in grants)
        if (g.id == grantId)
          RecordGrant(
            id: g.id,
            vetName: g.vetName,
            fromVisit: g.fromVisit,
            active: false,
            startsAt: g.startsAt,
            expiresAt: g.expiresAt,
            revokedAt: DateTime(2026, 11, 18, 13),
          )
        else
          g,
    ];
  }
}
