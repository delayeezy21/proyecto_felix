import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// La cuenta tiene una solicitud de eliminación vigente (`blocked`): el
/// servidor rechaza toda llamada con HTTP 403 y `hint: account_blocked`, salvo
/// `my_deletion_request`, `cancel_account_deletion` y `export_my_data`.
class AccountBlockedException implements Exception {
  const new();

  String get message =>
      'Tu cuenta está en proceso de borrado. Puedes cancelarlo o descargar '
      'tus datos.';

  @override
  String toString() => 'AccountBlockedException';
}

const accountBlockedHint = 'account_blocked';

/// true si el error de PostgREST es el bloqueo por eliminación de cuenta.
///
/// Con `maybeSingle()` postgrest-dart 2.x pierde el `hint` y deja el cuerpo
/// crudo en `message`, por eso también se busca ahí.
bool isAccountBlocked(PostgrestException e) =>
    e.hint == accountBlockedHint || e.message.contains(accountBlockedHint);

/// Aviso global de "cuenta bloqueada". Lo enciende cualquier respuesta 403
/// con `account_blocked` (ver [AccountBlockedHttpClient]) o un repositorio;
/// el router lo escucha y lleva a la pantalla de borrado en curso.
class AccountBlockedSignal extends ChangeNotifier {
  bool _blocked = false;

  bool get blocked => _blocked;

  void report() {
    if (_blocked) return;
    _blocked = true;
    notifyListeners();
  }

  void clear() {
    if (!_blocked) return;
    _blocked = false;
    notifyListeners();
  }
}

/// Cliente HTTP de Supabase (REST, RPC y Storage) que detecta el bloqueo en
/// cualquier respuesta y enciende [signal]. Así ninguna pantalla queda con
/// un error genérico: el router la reemplaza por la de borrado en curso.
class AccountBlockedHttpClient extends http.BaseClient {
  new(this.signal, [http.Client? inner]) : _inner = inner ?? http.Client();

  final AccountBlockedSignal signal;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode != 403) return response;
    // Las respuestas 403 son cortas: se leen para buscar el hint y se
    // devuelven intactas.
    final bytes = await response.stream.toBytes();
    if (_mentionsBlocked(bytes)) signal.report();
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  static bool _mentionsBlocked(Uint8List bytes) {
    try {
      return String.fromCharCodes(bytes).contains(accountBlockedHint);
    } on Object {
      return false;
    }
  }

  @override
  void close() => _inner.close();
}

/// Se reemplaza en `main` por la instancia que usa el cliente HTTP.
final accountBlockedSignalProvider = Provider<AccountBlockedSignal>((ref) {
  final signal = AccountBlockedSignal();
  ref.onDispose(signal.dispose);
  return signal;
});
