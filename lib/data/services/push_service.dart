import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/push.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Avisos push (FCM en Android, iOS y Web). Hoy la app usa [NoopPushService]:
/// Firebase aún no está configurado y los avisos dentro de la app salen del
/// refresco periódico y de Realtime (en Windows nunca habrá FCM).
///
/// Para activar FCM, ver docs/arquitectura.md §6 ("Push en la app").
abstract interface class PushService {
  /// Pide permiso, obtiene el token y lo registra (`register_push_device`).
  Future<void> start();

  /// Quita el token del servidor (al cerrar sesión).
  Future<void> stop();

  /// Avisos recibidos con la app abierta, ya validados ([PushPayload]).
  Stream<PushPayload> get messages;
}

class NoopPushService implements PushService {
  const new();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<PushPayload> get messages => const Stream.empty();
}

/// Plataformas que acepta `register_push_device`.
enum PushPlatform { android, ios, web }

/// Registro del token del dispositivo en el servidor. Lo usará la
/// implementación FCM de [PushService].
class PushDeviceRegistry {
  new(this._client);

  final SupabaseClient _client;

  Future<void> register(String token, PushPlatform platform) =>
      _client.rpc<void>(
        'register_push_device',
        params: {'p_token': token, 'p_platform': platform.name},
      );

  Future<void> unregister(String token) =>
      _client.rpc<void>('unregister_push_device', params: {'p_token': token});
}

final pushServiceProvider = Provider<PushService>(
  (ref) => const NoopPushService(),
);

/// Avisos recibidos (vacío con [NoopPushService]).
final StreamProvider<PushPayload> pushMessagesProvider =
    StreamProvider<PushPayload>(
      (ref) => ref.watch(pushServiceProvider).messages,
    );
