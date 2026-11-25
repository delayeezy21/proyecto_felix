import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Repositorio real contra un PostgREST falso (MockClient): RPC, parámetros,
/// lectura de las respuestas y traducción de errores (fase 11).
void main() {
  late List<(String, Map<String, dynamic>?)> calls;
  late http.Response Function(String rpc) respond;

  SupabaseClient client({AccountBlockedSignal? signal}) {
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
      httpClient: signal == null
          ? mock
          : AccountBlockedHttpClient(signal, mock),
    );
    addTearDown(c.dispose);
    return c;
  }

  SupabasePrivacyRepository repo({AccountBlockedSignal? signal}) =>
      SupabasePrivacyRepository(client(signal: signal));

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

  http.Response blocked() => pgError(
    '42501',
    'Tu cuenta está bloqueada por una solicitud de eliminación',
    hint: 'account_blocked',
    status: 403,
  );

  final statusJson = {
    'privacy_version': 'p-2',
    'last_seen_version': 'p-1',
    'must_review': true,
    'terms_version': 't-1',
    'purposes': [
      {
        'purpose': 'marketing',
        'description': 'Novedades',
        'granted': false,
        'granted_at': null,
        'last_revoked_at': '2026-11-20T12:00:00+00:00',
        'ask': false,
      },
    ],
    'history': [
      {
        'purpose': 'marketing',
        'version': 'p-1',
        'granted_at': '2026-11-01T12:00:00+00:00',
        'revoked_at': '2026-11-20T12:00:00+00:00',
      },
    ],
  };

  final deletionJson = {
    'request_id': 'd1',
    'status': 'blocked',
    'requested_at': '2026-11-25T12:00:00+00:00',
    'execute_after': '2026-12-10T12:00:00+00:00',
    'cancelled_at': null,
    'cancellable': true,
  };

  setUp(() {
    calls = [];
    respond = (_) => json({});
  });

  test('my_privacy_status: versión, aviso y finalidades', () async {
    respond = (_) => json(statusJson);
    final s = await repo().status();
    expect(calls.single.$1, 'my_privacy_status');
    expect(s.privacyVersion, 'p-2');
    expect(s.mustReview, isTrue);
    expect(s.purposes.single.purpose, 'marketing');
    expect(s.purposes.single.granted, isFalse);
    expect(s.purposes.single.lastRevokedAt, isNotNull);
    expect(s.history.single.revokedAt, isNotNull);
  });

  test('set_consent envía la finalidad y el valor', () async {
    respond = (_) => json(statusJson);
    await repo().setConsent('marketing', granted: false);
    expect(calls.single.$1, 'set_consent');
    expect(calls.single.$2, {'p_purpose': 'marketing', 'p_granted': false});
  });

  test('finalidad desconocida (22023) muestra el mensaje del servidor', () {
    respond = (_) => pgError('22023', 'Finalidad opcional desconocida');
    expect(
      repo().setConsent('otra', granted: true),
      throwsA(
        isA<PrivacyFailure>().having(
          (e) => e.message,
          'message',
          'Finalidad opcional desconocida',
        ),
      ),
    );
  });

  test('record_privacy_notice_view devuelve el estado nuevo', () async {
    respond = (_) => json({...statusJson, 'must_review': false});
    final s = await repo().recordNoticeView();
    expect(calls.single.$1, 'record_privacy_notice_view');
    expect(s.mustReview, isFalse);
  });

  test('export_my_data devuelve el JSON completo', () async {
    respond = (_) => json({
      'format': 'felix-export',
      'format_version': 1,
      'account': {'email': 'ana@ejemplo.cl'},
    });
    final data = await repo().exportMyData();
    expect(calls.single.$1, 'export_my_data');
    expect(data['format_version'], 1);
  });

  test('solicitud de borrado: pedir, consultar y cancelar', () async {
    respond = (_) => json(deletionJson);
    final r = await repo().requestDeletion();
    expect(calls.last.$1, 'request_account_deletion');
    expect(r.status, DeletionStatus.blocked);
    expect(r.cancellable, isTrue);
    expect(r.isActive, isTrue);
    expect(r.executeAfter, DateTime.utc(2026, 12, 10, 12).toLocal());

    respond = (_) => json({
      ...deletionJson,
      'status': 'cancelled',
      'cancellable': false,
      'cancelled_at': '2026-11-26T12:00:00+00:00',
    });
    final c = await repo().cancelDeletion();
    expect(calls.last.$1, 'cancel_account_deletion');
    expect(c.status, DeletionStatus.cancelled);
    expect(c.isActive, isFalse);
  });

  test('my_deletion_request sin solicitud devuelve null', () async {
    respond = (_) => json(null);
    expect(await repo().myDeletionRequest(), isNull);
    expect(calls.single.$1, 'my_deletion_request');
  });

  test('cancelar fuera de la gracia (22023) explica el motivo', () {
    respond = (_) => pgError(
      '22023',
      'El período de gracia terminó: la eliminación ya está en curso',
    );
    expect(
      repo().cancelDeletion(),
      throwsA(
        isA<PrivacyFailure>().having(
          (e) => e.message,
          'message',
          startsWith('El período de gracia terminó'),
        ),
      ),
    );
  });

  test('el admin no puede pedir el borrado (42501)', () {
    respond = (_) => pgError('42501', 'Esta cuenta se elimina por soporte');
    expect(
      repo().requestDeletion(),
      throwsA(
        isA<PrivacyFailure>().having(
          (e) => e.message,
          'message',
          'Esta cuenta se elimina por soporte',
        ),
      ),
    );
  });

  test('otro 42501 da un mensaje de permiso, sin detalles internos', () {
    respond = (_) => pgError('42501', 'No tienes acceso a esa entrada');
    expect(
      repo().requestRetainedEntry('e1', reason: 'Control de seguimiento'),
      throwsA(
        isA<PrivacyFailure>().having(
          (e) => e.message,
          'message',
          'No tienes permiso para esta acción.',
        ),
      ),
    );
  });

  test('account_blocked → AccountBlockedException', () {
    respond = (_) => blocked();
    expect(repo().status(), throwsA(isA<AccountBlockedException>()));
  });

  test('entradas retenidas: listar y consultar con motivo', () async {
    respond = (rpc) => rpc == 'list_my_retained_entries'
        ? json([
            {
              'id': 'e1',
              'created_at': '2026-01-10T12:00:00+00:00',
              'kind': 'consultation',
              'species': 'Perro',
              'retain_until': '2031-11-25T12:00:00+00:00',
            },
          ])
        : json({
            'id': 'e1',
            'created_at': '2026-01-10T12:00:00+00:00',
            'kind': 'vaccine',
            'species': 'Perro',
            'specialty': null,
            'title': 'Vacuna',
            'body': 'Sin reacciones. [redactado]',
            'retain_until': '2031-11-25T12:00:00+00:00',
            'vaccine': {
              'vaccine_name': 'Óctuple',
              'lot': 'L-1',
              'applied_on': '2026-01-10',
              'next_due': null,
            },
          });
    final list = await repo().retainedEntries();
    expect(list.single.species, 'Perro');
    final d = await repo().requestRetainedEntry(
      'e1',
      reason: '  Seguimiento de la vacuna  ',
    );
    expect(calls.last.$1, 'request_retained_entry');
    expect(calls.last.$2, {
      'p_entry_id': 'e1',
      'p_reason': 'Seguimiento de la vacuna',
    });
    expect(d.body, contains('[redactado]'));
    expect(d.vaccineName, 'Óctuple');
  });

  test('motivo corto (22023) muestra el mensaje del servidor', () {
    respond = (_) => pgError(
      '22023',
      'Indica el motivo de la consulta (10 a 500 caracteres)',
    );
    expect(
      repo().requestRetainedEntry('e1', reason: 'corto'),
      throwsA(
        isA<PrivacyFailure>().having(
          (e) => e.message,
          'message',
          contains('10 a 500'),
        ),
      ),
    );
  });

  group('cliente HTTP con aviso de bloqueo', () {
    test(
      'un 403 account_blocked enciende el aviso y conserva el error',
      () async {
        final signal = AccountBlockedSignal();
        addTearDown(signal.dispose);
        respond = (_) => blocked();
        await expectLater(
          repo(signal: signal).status(),
          throwsA(isA<AccountBlockedException>()),
        );
        expect(signal.blocked, isTrue);
      },
    );

    test('otro 403 no lo enciende', () async {
      final signal = AccountBlockedSignal();
      addTearDown(signal.dispose);
      respond = (_) => pgError('42501', 'permiso denegado', status: 403);
      await expectLater(
        repo(signal: signal).status(),
        throwsA(isA<PrivacyFailure>()),
      );
      expect(signal.blocked, isFalse);
    });

    test('fetchAccount con la cuenta bloqueada lanza la excepción de '
        'dominio', () async {
      final signal = AccountBlockedSignal();
      addTearDown(signal.dispose);
      respond = (_) => blocked();
      final c = client(signal: signal);
      // Sin usuario no consulta: se simula una sesión con un JWT de prueba.
      await c.auth.setInitialSession(
        jsonEncode({
          'access_token': _jwt,
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': 4102444800,
          'refresh_token': 'r',
          'user': {
            'id': '00000000-0000-0000-0000-000000000001',
            'aud': 'authenticated',
            'app_metadata': <String, dynamic>{},
            'user_metadata': <String, dynamic>{},
            'created_at': '2026-11-01T00:00:00Z',
          },
        }),
      );
      await expectLater(
        SupabaseProfileRepository(c).fetchAccount(),
        throwsA(isA<AccountBlockedException>()),
      );
      expect(signal.blocked, isTrue);
    });
  });
}

/// JWT sin firma válida (el MockClient no lo verifica); vence en 2100.
const _jwt =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
    'eyJzdWIiOiIwMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0w'
    'MDAwMDAwMDAwMDEiLCJleHAiOjQxMDI0NDQ4MDB9.'
    'firma';
