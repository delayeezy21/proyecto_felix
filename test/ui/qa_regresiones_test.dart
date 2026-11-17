// Regresiones de UI de los defectos encontrados por el QA (docs/qa/QA-c251867.md
// y docs/qa/QA-d0c586c.md). Los defectos abiertos quedan con `skip`: al
// corregirlos, quita el `skip` para que la prueba quede activa.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeVetRepository vets;

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
    vets = FakeVetRepository(
      profile: VetProfile(
        userId: 'v1',
        displayName: 'Dra. Vera',
        status: VetStatus.pending,
        university: 'Universidad de Chile',
        graduationYear: 2015,
        declarationAcceptedAt: DateTime(2026, 11, 10),
        submittedAt: DateTime(2026, 11, 10),
      ),
    );
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 3200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(auth: auth, profiles: profiles, vets: vets),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('en revisión, los datos profesionales se muestran bloqueados', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('En revisión'), findsOneWidget);
    expect(find.byKey(const Key('vet-university')), findsNothing);
    expect(find.byKey(const Key('vet-submit')), findsNothing);
  });

  testWidgets(
    'QA-12: en revisión, las especies y especialidades enviadas no se '
    'cambian desde la UI',
    (tester) async {
      await open(tester);
      final chip = tester.widget<FilterChip>(
        find.byKey(const Key('chip-species-perro')),
      );
      expect(
        chip.onSelected,
        isNull,
        reason: 'la solicitud está en revisión: el admin revisa lo enviado',
      );
    },
  );

  // --- QA de la versión d0c586c (docs/qa/QA-d0c586c.md) ---------------------

  group('QA-15: el aviso "Guardando…" no queda pegado', () {
    setUp(() {
      vets.profile = const VetProfile(
        userId: 'v1',
        displayName: 'Dra. Vera',
        status: VetStatus.pending,
        university: 'Universidad de Chile',
        graduationYear: 2015,
      );
    });

    testWidgets('si el vet escribe y deshace antes del autoguardado', (
      tester,
    ) async {
      await open(tester);
      final field = find.byKey(const Key('vet-university'));
      await tester.enterText(field, 'Universidad de Chilex');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(field, 'Universidad de Chile');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('vet-saving-before-submit')),
        findsNothing,
        reason: 'no hay nada que guardar: el envío no debe quedar bloqueado',
      );
    });

    testWidgets('si el dato queda inválido (no se autoguarda)', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const Key('vet-year')), '19');
      await tester.pump(const Duration(seconds: 2));
      await tester.enterText(find.byKey(const Key('vet-year')), '2015');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vet-saving-before-submit')), findsNothing);
    });
  });

  // --- QA de la versión eaa4a89 (docs/qa/QA-eaa4a89.md) ---------------------

  group(
    'QA-17: no se envía con datos en pantalla distintos de los guardados',
    () {
      late _SlowVetRepository slow;

      setUp(() {
        slow = _SlowVetRepository(
          profile: VetProfile(
            userId: 'v1',
            displayName: 'Dra. Vera',
            status: VetStatus.pending,
            university: 'Universidad de Chile',
            graduationYear: 2015,
            declarationAcceptedAt: DateTime(2026, 11, 10),
          ),
        );
        slow.species.add(1);
        slow.specialties.add(1);
        for (final k in [
          VetDocumentKind.degreeCertificate,
          VetDocumentKind.idCardFront,
        ]) {
          slow.documents.add(
            VetDocument(
              id: k.dbValue,
              kind: k,
              mime: 'application/pdf',
              sizeBytes: 10,
              uploadedAt: DateTime(2026, 11, 10),
              reviewStatus: 'pending',
              storagePath: 'v1/${k.dbValue}.pdf',
            ),
          );
        }
        vets = slow;
      });

      FilledButton submit(WidgetTester tester) =>
          tester.widget<FilledButton>(find.byKey(const Key('vet-submit')));

      testWidgets('con un dato inválido sin guardar', (tester) async {
        await open(tester);
        expect(
          submit(tester).onPressed,
          isNotNull,
          reason: 'solicitud completa',
        );
        await tester.enterText(find.byKey(const Key('vet-year')), '19');
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(
          submit(tester).onPressed,
          isNull,
          reason: 'en pantalla dice 19 (inválido) y se enviaría 2015',
        );
      }, skip: true); // QA-17 abierto: quitar al corregir.

      testWidgets('con una edición hecha durante un guardado en curso', (
        tester,
      ) async {
        slow.saveDelay = const Duration(seconds: 2);
        await open(tester);
        final field = find.byKey(const Key('vet-university'));
        await tester.enterText(field, 'Universidad de Chile X');
        // t = 1,5 s: el primer autoguardado (inició a 0,9 s) sigue en curso.
        await tester.pump(const Duration(milliseconds: 1500));
        await tester.enterText(field, 'Universidad de Chile XY');
        // t = 3,0 s: terminó el primero; el segundo (inició a 2,4 s) sigue.
        await tester.pump(const Duration(milliseconds: 1500));
        expect(
          find.byKey(const Key('vet-saving-before-submit')),
          findsOneWidget,
          reason: 'el segundo guardado sigue en curso: aún no se puede enviar',
        );
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
      }, skip: true); // QA-17 abierto: quitar al corregir.
    },
  );

  group('QA-14: documentos eliminados sin verificar', () {
    VetDocument purged(VetDocumentKind k, String review) => VetDocument(
      id: k.dbValue,
      kind: k,
      mime: 'application/pdf',
      sizeBytes: 10,
      uploadedAt: DateTime(2026, 8, 2),
      reviewStatus: review,
      purgedAt: DateTime(2026, 11, 2),
    );

    testWidgets('un borrador vencido pide volver a subir, sin decir '
        '"verificado"', (tester) async {
      vets
        ..profile = const VetProfile(
          userId: 'v1',
          displayName: 'Dra. Vera',
          status: VetStatus.pending,
        )
        ..documents.addAll([
          purged(VetDocumentKind.degreeCertificate, 'pending'),
          purged(VetDocumentKind.idCardFront, 'rejected'),
        ]);
      await open(tester);
      expect(
        find.text('Eliminado por vencimiento (90 días): súbelo de nuevo'),
        findsOneWidget,
      );
      expect(
        find.text('Eliminado tras el rechazo: súbelo de nuevo'),
        findsOneWidget,
      );
      expect(find.textContaining('verificados y eliminados'), findsNothing);
      expect(find.text('Verificado y eliminado'), findsNothing);
      expect(find.textContaining('Certificado de título'), findsWidgets);
      expect(find.textContaining('Te falta:'), findsOneWidget);
    });

    testWidgets('un vet aprobado con documentos purgados sí ve "verificados"', (
      tester,
    ) async {
      profiles.accounts['v1'] = const Account(
        role: AppRole.vet,
        displayName: 'Dra. Vera',
        vetStatus: VetStatus.approved,
      );
      vets
        ..profile = VetProfile(
          userId: 'v1',
          displayName: 'Dra. Vera',
          status: VetStatus.approved,
          submittedAt: DateTime(2026, 11, 2),
        )
        ..documents.addAll([
          purged(VetDocumentKind.degreeCertificate, 'accepted'),
          purged(VetDocumentKind.idCardFront, 'accepted'),
        ]);
      await open(tester);
      expect(find.textContaining('verificados y eliminados'), findsOneWidget);
      expect(find.text('Verificado y eliminado'), findsNWidgets(2));
    });
  });
}

/// Repositorio con guardado lento, para simular la latencia de la red.
class _SlowVetRepository extends FakeVetRepository {
  new({super.profile});

  Duration saveDelay = Duration.zero;

  @override
  Future<void> updateProfessionalData({
    required String? bio,
    required String? university,
    required int? graduationYear,
    required bool foreignDegree,
    required String? titleVerificationCode,
  }) async {
    await Future<void>.delayed(saveDelay);
    await super.updateProfessionalData(
      bio: bio,
      university: university,
      graduationYear: graduationYear,
      foreignDegree: foreignDegree,
      titleVerificationCode: titleVerificationCode,
    );
  }
}
