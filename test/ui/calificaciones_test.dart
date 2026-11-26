import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/rating_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/rating.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/features/ratings/view_models/rating_providers.dart';
import 'package:proyecto_felix/ui/features/ratings/views/vet_ratings_card.dart';

import '../helpers/fakes.dart';

/// Fase 9: calificaciones (dueño y vet), resumen del vet, moderación y
/// alertas de cancelación del admin, con repositorios falsos.
void main() {
  void bigView(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(800, 2600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  late FakeRatingRepository ratings;

  setUp(() => ratings = FakeRatingRepository());

  group('ViewModels', () {
    ProviderContainer container() {
      final c = ProviderContainer(
        retry: _noRetry,
        overrides: [ratingRepositoryProvider.overrideWithValue(ratings)],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('calificar actualiza el estado; "ya calificó" recarga', () async {
      final c = container();
      final p = visitRatingProvider('vis1');
      final sub = c.listen(p, (_, _) {});
      addTearDown(sub.close);
      expect((await c.read(p.future)).canRate, isTrue);

      await c.read(p.notifier).rate(stars: 5, comment: ' Excelente ');
      expect(c.read(p).value!.mine!.stars, 5);
      expect(ratings.rateCalls.single, ('vis1', 5, 'Excelente'));

      final before = ratings.statusCalls;
      await expectLater(
        c.read(p.notifier).rate(stars: 3),
        throwsA(isA<RatingFailure>()),
      );
      await c.read(p.future);
      expect(ratings.statusCalls, before + 1);
    });

    test(
      'admin: ocultar cambia la fila y revisar recarga las alertas',
      () async {
        ratings
          ..adminRatings = [_adminRating()]
          ..alerts = [_alert()];
        final c = container();
        final subA = c.listen(adminRatingsProvider, (_, _) {});
        final subB = c.listen(cancelAlertsProvider(false), (_, _) {});
        addTearDown(subA.close);
        addTearDown(subB.close);
        await c.read(adminRatingsProvider.future);
        await c
            .read(adminRatingsProvider.notifier)
            .setHidden('r1', hidden: true);
        expect(c.read(adminRatingsProvider).value!.single.hidden, isTrue);

        expect(await c.read(cancelAlertsProvider(false).future), hasLength(1));
        await c.read(cancelAlertsProvider(false).notifier).review('al1');
        expect(await c.read(cancelAlertsProvider(false).future), isEmpty);
        expect(ratings.reviewCalls, ['al1']);
      },
    );
  });

  testWidgets('al elegir vet: promedio público solo si lo tiene', (
    tester,
  ) async {
    ratings.vetSummaries['v1'] = const VetRatingSummary(
      vetId: 'v1',
      ratingAvg: 4.5,
      ratingCount: 8,
    );
    ratings.vetSummaries['v2'] = const VetRatingSummary(
      vetId: 'v2',
      ratingCount: 1,
    );
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        retry: _noRetry,
        overrides: [ratingRepositoryProvider.overrideWithValue(ratings)],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                VetRatingBadge(vetId: 'v1'),
                VetRatingBadge(vetId: 'v2'),
                VetRatingBadge(vetId: 'v3'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('vet-badge-v1')), findsOneWidget);
    expect(find.text('4,5 (8)'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Calificación 4,5 de 5, 8 calificaciones'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('vet-badge-v2')), findsNothing);
    expect(find.byKey(const Key('vet-badge-v3')), findsNothing);
    semantics.dispose();
  });

  group('dueño', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeVisitRepository visits;

    setUp(() {
      auth = FakeAuthRepository(userId: 'o1');
      profiles = FakeProfileRepository(
        auth,
        accounts: {
          'o1': const Account(role: AppRole.owner, displayName: 'Ana'),
        },
      );
      visits = FakeVisitRepository()
        ..visits = [ownerVisit(status: VisitStatus.completed)];
    });

    Future<void> openVisit(WidgetTester tester) async {
      bigView(tester);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          visits: visits,
          ratings: ratings,
          retry: _noRetry,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Visitas'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('visit-vis1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('visit-rating-card')));
      await tester.pumpAndSettle();
    }

    testWidgets('califica con estrellas accesibles y ve "Tu calificación"', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openVisit(tester);
      expect(find.text('Calificar'), findsOneWidget);
      expect(find.byKey(const Key('rating-until')), findsOneWidget);
      expect(find.textContaining('30 nov'), findsWidgets);

      // Sin estrellas no se puede enviar.
      final submit = find.byKey(const Key('rating-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);

      // Etiquetas semánticas y tamaño táctil.
      expect(find.bySemanticsLabel('3 de 5 estrellas'), findsOneWidget);
      final size = tester.getSize(find.byKey(const Key('rating-star-3')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));

      await tester.tap(find.byKey(const Key('rating-star-4')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('rating-comment')),
        'Muy amable',
      );
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(ratings.rateCalls.single, ('vis1', 4, 'Muy amable'));
      expect(find.text('Tu calificación'), findsOneWidget);
      expect(find.bySemanticsLabel('4 de 5 estrellas'), findsOneWidget);
      expect(find.text('Muy amable'), findsOneWidget);
      expect(find.byKey(const Key('rating-pending')), findsOneWidget);
      expect(find.byKey(const Key('rating-submit')), findsNothing);
      semantics.dispose();
    });

    testWidgets('con ambas publicadas ve "Su calificación"; comentario '
        'oculto', (tester) async {
      ratings.statuses['vis1'] = ratingStatus(
        canRate: false,
        mine: const MyRating(stars: 5, comment: 'Gracias', hidden: true),
        theirs: const TheirRating(stars: 4, commentHidden: true),
      );
      await openVisit(tester);
      expect(find.text('Tu calificación'), findsOneWidget);
      expect(find.byKey(const Key('rating-mine-hidden')), findsOneWidget);
      expect(find.text('Gracias'), findsNothing);
      expect(find.text('Su calificación'), findsOneWidget);
      expect(find.byKey(const Key('rating-theirs-hidden')), findsOneWidget);
      expect(find.byKey(const Key('rating-pending')), findsNothing);
    });

    testWidgets('plazo vencido: no muestra el formulario', (tester) async {
      ratings.statuses['vis1'] = ratingStatus(
        canRate: false,
        rateUntil: DateTime(2026, 11, 20, 12),
      );
      await openVisit(tester);
      expect(find.byKey(const Key('rating-expired')), findsOneWidget);
      expect(find.textContaining('venció'), findsOneWidget);
      expect(find.byKey(const Key('rating-submit')), findsNothing);
    });

    testWidgets('error al cargar y reintento', (tester) async {
      ratings.nextFailure = const RatingFailure('Sin conexión (prueba).');
      await openVisit(tester);
      expect(find.text('Sin conexión (prueba).'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rating-retry')));
      await tester.pumpAndSettle();
      expect(find.text('Calificar'), findsOneWidget);
    });

    testWidgets('un error al enviar se muestra y mantiene el formulario', (
      tester,
    ) async {
      await openVisit(tester);
      await tester.tap(find.byKey(const Key('rating-star-2')));
      await tester.pump();
      ratings.nextFailure = const RatingFailure(
        'El plazo para calificar venció (7 días)',
      );
      await tester.tap(find.byKey(const Key('rating-submit')));
      await tester.pumpAndSettle();
      expect(
        find.text('El plazo para calificar venció (7 días)'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('rating-submit')), findsOneWidget);
    });

    testWidgets('"ya calificó" recarga y muestra su calificación', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openVisit(tester);
      // Otra sesión calificó mientras tanto.
      ratings.statuses['vis1'] = ratingStatus(
        canRate: false,
        mine: const MyRating(stars: 3),
      );
      await tester.tap(find.byKey(const Key('rating-star-5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('rating-submit')));
      await tester.pumpAndSettle();
      expect(find.text('Tu calificación'), findsOneWidget);
      expect(find.bySemanticsLabel('3 de 5 estrellas'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('una visita no completada no se califica', (tester) async {
      visits.visits = [ownerVisit(status: VisitStatus.accepted)];
      bigView(tester);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          visits: visits,
          ratings: ratings,
          retry: _noRetry,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Visitas'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('visit-vis1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('visit-rating-card')), findsNothing);
      expect(ratings.statusCalls, 0);
    });
  });

  group('veterinario', () {
    late FakeAuthRepository auth;
    late FakeProfileRepository profiles;
    late FakeVisitRepository visits;
    late FakeVetRepository vets;

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
    });

    Future<void> open(WidgetTester tester) async {
      bigView(tester);
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          vets: vets,
          visits: visits,
          ratings: ratings,
          retry: _noRetry,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('califica al dueño desde su visita completada', (tester) async {
      visits.visits = [vetVisit(status: VisitStatus.completed)];
      ratings.statuses['vis1'] = ratingStatus(role: 'vet');
      await open(tester);
      await tester.tap(find.byKey(const Key('vet-open-visits')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vet-rate-vis1')));
      await tester.pumpAndSettle();
      expect(find.text('¿Cómo fue la visita con el dueño?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rating-star-5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('rating-submit')));
      await tester.pumpAndSettle();
      expect(ratings.rateCalls.single, ('vis1', 5, null));
      expect(find.textContaining('La calificación del dueño'), findsOneWidget);
      expect(find.byKey(const Key('rating-pending')), findsOneWidget);
    });

    testWidgets('perfil: pocas calificaciones y contador de cancelaciones', (
      tester,
    ) async {
      ratings.summary = const RatingSummary(
        ratingCount: 2,
        minRatings: 3,
        cancelCount30d: 3,
      );
      await open(tester);
      await tester.ensureVisible(find.byKey(const Key('vet-ratings-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vet-rating-few')), findsOneWidget);
      expect(
        find.textContaining('Aún sin calificaciones suficientes'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Cancelaciones en los últimos 30 días: 3'),
        findsOneWidget,
      );
      expect(find.textContaining('alerta para el administrador'), findsOne);
      expect(find.byKey(const Key('vet-ratings-empty')), findsOneWidget);
    });

    testWidgets('perfil: promedio y recibidas sin autor', (tester) async {
      ratings
        ..summary = const RatingSummary(
          ratingCount: 4,
          ratingAvg: 4.25,
          minRatings: 3,
          cancelCount30d: 0,
        )
        ..receivedList = [
          ReceivedRating(
            visitId: 'vis1',
            raterRole: 'owner',
            stars: 5,
            comment: 'Excelente',
            publishedAt: DateTime(2026, 11, 22),
          ),
          const ReceivedRating(
            visitId: 'vis2',
            raterRole: 'owner',
            stars: 2,
            commentHidden: true,
          ),
        ];
      await open(tester);
      await tester.ensureVisible(find.byKey(const Key('vet-ratings-card')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('vet-rating-avg')), findsOneWidget);
      expect(find.text('4,3'), findsOneWidget);
      expect(find.text('(4 calificaciones)'), findsOneWidget);
      expect(find.textContaining('Excelente'), findsOneWidget);
      expect(find.textContaining('oculto por moderación'), findsOneWidget);
      expect(find.byKey(const Key('vet-rating-1')), findsOneWidget);
    });

    testWidgets('perfil: error del resumen con reintento', (tester) async {
      ratings.nextFailure = const RatingFailure('Falla de prueba.');
      await open(tester);
      await tester.ensureVisible(find.byKey(const Key('vet-ratings-card')));
      await tester.pumpAndSettle();
      expect(find.text('Falla de prueba.'), findsOneWidget);
    });
  });

  group('admin', () {
    Future<void> openTab(WidgetTester tester, String tab) async {
      bigView(tester);
      final auth = FakeAuthRepository(userId: 'ad1');
      final profiles = FakeProfileRepository(
        auth,
        accounts: {
          'ad1': const Account(role: AppRole.admin, displayName: 'Admin'),
        },
      );
      await tester.pumpWidget(
        testApp(
          auth: auth,
          profiles: profiles,
          ratings: ratings,
          retry: _noRetry,
        ),
      );
      await tester.pumpAndSettle();
      await openAdminSection(tester, tab);
    }

    testWidgets('lista calificaciones y oculta o muestra el comentario', (
      tester,
    ) async {
      ratings.adminRatings = [_adminRating()];
      await openTab(tester, 'Calificaciones');
      expect(find.byKey(const Key('admin-rating-r1')), findsOneWidget);
      expect(find.text('Sin publicar'), findsOneWidget);
      expect(find.text('Llegó tarde'), findsOneWidget);

      await tester.tap(find.byKey(const Key('admin-rating-toggle-r1')));
      await tester.pumpAndSettle();
      expect(ratings.hiddenCalls.single, ('r1', true));
      expect(find.byKey(const Key('admin-rating-hidden-r1')), findsOneWidget);
      expect(find.text('Mostrar comentario'), findsOneWidget);

      await tester.tap(find.byKey(const Key('admin-rating-toggle-r1')));
      await tester.pumpAndSettle();
      expect(ratings.hiddenCalls.last, ('r1', false));
      expect(find.byKey(const Key('admin-rating-hidden-r1')), findsNothing);
    });

    testWidgets('sin calificaciones: estado vacío', (tester) async {
      await openTab(tester, 'Calificaciones');
      expect(find.byKey(const Key('admin-ratings-empty')), findsOneWidget);
    });

    testWidgets('alertas: marca revisada y muestra las revisadas', (
      tester,
    ) async {
      ratings.alerts = [_alert()];
      await openTab(tester, 'Alertas de cancelación');
      expect(find.byKey(const Key('admin-alert-al1')), findsOneWidget);
      expect(find.textContaining('en los últimos 30 días: 4'), findsOneWidget);

      await tester.tap(find.byKey(const Key('admin-alert-review-al1')));
      await tester.pumpAndSettle();
      expect(ratings.reviewCalls, ['al1']);
      expect(find.byKey(const Key('admin-alerts-empty')), findsOneWidget);

      await tester.tap(find.byKey(const Key('alerts-include-reviewed')));
      await tester.pumpAndSettle();
      expect(ratings.alertQueries.last, isTrue);
      expect(find.byKey(const Key('admin-alert-reviewed-al1')), findsOneWidget);
    });

    testWidgets('alertas: error al cargar', (tester) async {
      ratings.nextFailure = const RatingFailure('Falla de prueba.');
      await openTab(tester, 'Alertas de cancelación');
      expect(find.text('Falla de prueba.'), findsOneWidget);
    });
  });
}

AdminRating _adminRating() => AdminRating(
  id: 'r1',
  visitId: 'vis1',
  raterRole: 'owner',
  stars: 2,
  comment: 'Llegó tarde',
  hidden: false,
  published: false,
  createdAt: DateTime(2026, 11, 24, 10),
);

CancelAlert _alert() => CancelAlert(
  id: 'al1',
  vetId: 'v1',
  vetName: 'Dra. Vera',
  cancelCount: 3,
  cancelCount30d: 4,
  lastCancelAt: DateTime(2026, 11, 20, 10),
);

/// Sin reintentos automáticos de Riverpod: el error queda a la vista.
Duration? _noRetry(int _, Object _) => null;
