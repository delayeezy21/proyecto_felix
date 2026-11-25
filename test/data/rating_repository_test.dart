import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proyecto_felix/data/repositories/rating_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Repositorio real contra un PostgREST falso (MockClient): RPC, parámetros,
/// lectura de las respuestas y traducción de errores (fase 9).
void main() {
  late List<(String, Map<String, dynamic>?)> calls;
  late http.Response Function(String rpc) respond;

  SupabaseRatingRepository repo() {
    final mock = MockClient((req) async {
      final rpc = req.url.pathSegments.last;
      final body = req.body.isEmpty ? null : jsonDecode(req.body);
      calls.add((rpc, body is Map ? body.cast<String, dynamic>() : null));
      final r = respond(rpc);
      return http.Response(
        r.body,
        r.statusCode,
        headers: r.headers,
        request: req,
      );
    });
    final c = SupabaseClient(
      'http://127.0.0.1:54321',
      'clave-de-prueba',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: mock,
    );
    addTearDown(c.dispose);
    return SupabaseRatingRepository(c);
  }

  http.Response json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response pgError(
    String code,
    String message, {
    String? hint,
    int status = 400,
  }) => json({
    'code': code,
    'message': message,
    'details': null,
    'hint': hint,
  }, status);

  final statusJson = {
    'visit_id': 'vis1',
    'my_role': 'owner',
    'rate_until': '2026-11-30T15:00:00Z',
    'can_rate': false,
    'mine': {
      'stars': 4,
      'comment': 'Muy amable',
      'hidden': false,
      'created_at': '2026-11-24T15:00:00Z',
      'publishes_at': '2026-11-30T15:00:00Z',
    },
    'theirs': {
      'stars': 5,
      'comment': null,
      'comment_hidden': true,
      'published_at': '2026-11-25T15:00:00Z',
    },
  };

  setUp(() => calls = []);

  test('rate_visit envía estrellas y comentario recortado (vacío → null) y '
      'lee el estado', () async {
    respond = (_) => json(statusJson);
    final s = await repo().rate('vis1', stars: 4, comment: '  Muy amable ');
    expect(calls.single.$1, 'rate_visit');
    expect(calls.single.$2, {
      'p_visit_id': 'vis1',
      'p_stars': 4,
      'p_comment': 'Muy amable',
    });
    expect(s.isOwner, isTrue);
    expect(s.canRate, isFalse);
    expect(s.mine!.stars, 4);
    expect(s.theirs!.commentHidden, isTrue);
    expect(s.theirs!.comment, isNull);

    await repo().rate('vis1', stars: 2, comment: '   ');
    expect(calls.last.$2!['p_comment'], isNull);
  });

  test('visit_rating_status sin calificaciones', () async {
    respond = (_) => json({
      'visit_id': 'vis1',
      'my_role': 'vet',
      'rate_until': null,
      'can_rate': false,
      'mine': null,
      'theirs': null,
    });
    final s = await repo().status('vis1');
    expect(calls.single.$1, 'visit_rating_status');
    expect(calls.single.$2, {'p_visit_id': 'vis1'});
    expect(s.isOwner, isFalse);
    expect(s.rateUntil, isNull);
    expect(s.mine, isNull);
    expect(s.expiredAt(DateTime(2030)), isFalse);
  });

  group('errores', () {
    Future<Object?> failWith(http.Response r) async {
      respond = (_) => r;
      try {
        await repo().rate('vis1', stars: 3);
      } on Object catch (e) {
        return e;
      }
      return null;
    }

    test('23505 → ya calificó', () async {
      final e = await failWith(pgError('23505', 'Ya calificaste esta visita'));
      expect(e, isA<RatingFailure>().having((f) => f.alreadyRated, 'ya', true));
    });

    test('22023 → mensaje del servidor (plazo vencido)', () async {
      final e = await failWith(
        pgError('22023', 'El plazo para calificar venció (7 días)'),
      );
      expect(
        e,
        isA<RatingFailure>().having(
          (f) => f.message,
          'msg',
          'El plazo para calificar venció (7 días)',
        ),
      );
    });

    test('42501 de visita ajena → sin permiso', () async {
      final e = await failWith(
        pgError('42501', 'No participaste en esta visita', status: 403),
      );
      expect(
        e,
        isA<RatingFailure>().having(
          (f) => f.message,
          'msg',
          contains('No puedes calificar'),
        ),
      );
    });

    test('la cuenta bloqueada de la otra parte no es la mía', () async {
      final e = await failWith(
        pgError(
          '22023',
          'La otra cuenta tiene una solicitud de eliminación: no se puede '
              'calificar',
          hint: 'counterpart_blocked',
        ),
      );
      expect(e, isA<RatingFailure>());
    });

    test(
      'mi cuenta bloqueada (pre-request) → AccountBlockedException',
      () async {
        final e = await failWith(
          pgError(
            '42501',
            'Tu cuenta está bloqueada por una solicitud de eliminación',
            hint: accountBlockedHint,
            status: 403,
          ),
        );
        expect(e, isA<AccountBlockedException>());
      },
    );
  });

  test('resumen, recibidas y promedio público', () async {
    respond = (rpc) => switch (rpc) {
      'my_rating_summary' => json({
        'rating_avg': 4.33,
        'rating_count': 3,
        'min_ratings': 3,
        'cancel_count_30d': 2,
      }),
      'my_ratings_received' => json([
        {
          'visit_id': 'vis1',
          'rater_role': 'owner',
          'stars': 5,
          'comment': null,
          'comment_hidden': true,
          'published_at': '2026-11-25T15:00:00Z',
        },
      ]),
      _ => json(null),
    };
    final r = repo();
    final s = await r.mySummary();
    expect(s.hasAverage, isTrue);
    expect(s.cancelCount30d, 2);
    final list = await r.received();
    expect(list.single.commentHidden, isTrue);
    expect(calls[1].$2, {'p_limit': 50});
    expect(await r.vetSummary('v1'), isNull);
    expect(calls.last.$1, 'vet_rating_summary');
    expect(calls.last.$2, {'p_vet_id': 'v1'});
  });

  test('admin: lista, oculta y alertas', () async {
    respond = (rpc) => switch (rpc) {
      'admin_list_ratings' => json([
        {
          'id': 'r1',
          'visit_id': 'vis1',
          'rater_id': 'o1',
          'ratee_id': 'v1',
          'rater_role': 'owner',
          'stars': 2,
          'comment': 'Llegó tarde',
          'hidden': false,
          'created_at': '2026-11-24T15:00:00Z',
          'publishes_at': '2026-11-30T15:00:00Z',
          'published': false,
        },
      ]),
      'admin_set_rating_hidden' => json({'id': 'r1', 'hidden': true}),
      'admin_list_cancel_alerts' => json([
        {
          'id': 'al1',
          'vet_id': 'v1',
          'vet_name': 'Dra. Vera',
          'cancel_count': 3,
          'cancel_count_30d': 4,
          'first_cancel_at': '2026-11-01T15:00:00Z',
          'last_cancel_at': '2026-11-20T15:00:00Z',
          'created_at': '2026-11-20T15:00:00Z',
          'reviewed_at': null,
        },
      ]),
      _ => json({'id': 'al1', 'vet_id': 'v1', 'reviewed_at': 'x'}),
    };
    final r = repo();
    final list = await r.adminList();
    expect(list.single.published, isFalse);
    expect(await r.adminSetHidden('r1', hidden: true), isTrue);
    expect(calls[1].$2, {'p_rating_id': 'r1', 'p_hidden': true});
    final alerts = await r.adminCancelAlerts(includeReviewed: true);
    expect(calls[2].$2, {'p_include_reviewed': true});
    expect(alerts.single.cancelCount30d, 4);
    expect(alerts.single.reviewed, isFalse);
    await r.adminReviewCancelAlert('al1');
    expect(calls.last.$1, 'admin_review_cancel_alert');
    expect(calls.last.$2, {'p_alert_id': 'al1'});
  });
}
