import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/ui/features/vet/view_models/vet_providers.dart';

void main() {
  group('validateDocument (igual que el bucket vet-documents)', () {
    test('acepta PDF, JPG, JPEG y PNG', () {
      for (final n in ['a.pdf', 'b.JPG', 'c.jpeg', 'd.png']) {
        expect(
          validateDocument(PickedDocument(name: n, bytes: const [1])),
          isNull,
          reason: n,
        );
      }
    });
    test('rechaza otros tipos, vacíos y > 5 MB', () {
      expect(
        validateDocument(const PickedDocument(name: 'x.docx', bytes: [1])),
        isNotNull,
      );
      expect(
        validateDocument(const PickedDocument(name: 'x.pdf', bytes: [])),
        isNotNull,
      );
      expect(
        validateDocument(
          PickedDocument(
            name: 'x.pdf',
            bytes: List.filled(maxDocumentBytes + 1, 0),
          ),
        ),
        'El archivo supera los 5 MB.',
      );
    });
  });

  test('formatMinutes', () {
    expect(formatMinutes(0), '00:00');
    expect(formatMinutes(570), '09:30');
    expect(formatMinutes(1440), '24:00');
  });

  group('VetProfile.canEditProfessionalData', () {
    VetProfile p(VetStatus s, {DateTime? submitted}) => VetProfile(
      userId: 'v',
      displayName: 'V',
      status: s,
      submittedAt: submitted,
    );
    test('editable antes de enviar y tras un rechazo', () {
      expect(p(VetStatus.pending).canEditProfessionalData, isTrue);
      expect(p(VetStatus.rejected).canEditProfessionalData, isTrue);
    });
    test('bloqueado en revisión, aprobado o suspendido', () {
      expect(
        p(VetStatus.pending, submitted: DateTime(2026)).canEditProfessionalData,
        isFalse,
      );
      expect(p(VetStatus.approved).canEditProfessionalData, isFalse);
      expect(p(VetStatus.suspended).canEditProfessionalData, isFalse);
    });
  });

  test('missingRequirements lista lo que falta en orden', () {
    final missing = missingRequirements(
      profile: const VetProfile(
        userId: 'v',
        displayName: 'V',
        status: VetStatus.pending,
        university: 'U',
        graduationYear: 2015,
      ),
      species: {1},
      specialties: const {},
      documents: const [],
    );
    expect(missing, [
      'Al menos una especialidad',
      'Certificado de título',
      'Cédula de identidad (anverso)',
      'Declaración jurada',
    ]);
  });
}
