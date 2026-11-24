import 'dart:async';

import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lo que llega por el canal de la visita.
sealed class LiveEvent {
  const new();
}

/// Nueva posición del vet.
class LivePosition extends LiveEvent {
  const new(this.location);

  final LiveLocation location;
}

/// El vet dejó de compartir (llegó o canceló): hay que salir del canal.
class LiveEnded extends LiveEvent {
  const new();
}

/// Sesión en el canal privado `visit:{id}`. Hay que llamar a [leave] al
/// pasar a "llegó" o cancelada: Realtime revisa la política solo al unirse.
abstract interface class LiveLocationSession {
  /// Eventos recibidos (solo el dueño y el vet asignado pueden unirse).
  Stream<LiveEvent> get events;

  /// Solo el vet asignado puede enviar.
  Future<void> send(LiveLocation location);

  /// Aviso final del vet antes de salir.
  Future<void> sendEnd();

  Future<void> leave();
}

/// Ubicación en vivo del vet en camino (Realtime Broadcast, sin guardar el
/// recorrido; docs/arquitectura.md §6).
abstract interface class LiveLocationService {
  LiveLocationSession join(String visitId);
}

const _locationEvent = 'location';
const _endEvent = 'end';

class SupabaseLiveLocationService implements LiveLocationService {
  new(this._client);

  final SupabaseClient _client;

  @override
  LiveLocationSession join(String visitId) {
    final events = StreamController<LiveEvent>.broadcast();
    final channel = _client.channel(
      'visit:$visitId',
      opts: const RealtimeChannelConfig(private: true),
    );
    // El callback trae el mensaje completo ({type, event, payload}).
    Map<String, dynamic> inner(Map<String, dynamic> m) =>
        m['payload'] is Map ? (m['payload'] as Map).cast<String, dynamic>() : m;
    channel
      ..onBroadcast(
        event: _locationEvent,
        callback: (m) {
          final loc = LiveLocation.tryParse(inner(m));
          if (loc != null && !events.isClosed) events.add(LivePosition(loc));
        },
      )
      ..onBroadcast(
        event: _endEvent,
        callback: (_) {
          if (!events.isClosed) events.add(const LiveEnded());
        },
      )
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.channelError &&
            !events.isClosed) {
          events.addError(error ?? StateError('realtime'));
        }
      });
    return _SupabaseSession(_client, channel, events);
  }
}

class _SupabaseSession implements LiveLocationSession {
  new(this._client, this._channel, this._events);

  final SupabaseClient _client;
  final RealtimeChannel _channel;
  final StreamController<LiveEvent> _events;
  bool _left = false;

  @override
  Stream<LiveEvent> get events => _events.stream;

  @override
  Future<void> send(LiveLocation location) async {
    if (_left) return;
    await _channel.sendBroadcastMessage(
      event: _locationEvent,
      payload: location.toPayload(),
    );
  }

  @override
  Future<void> sendEnd() async {
    if (_left) return;
    // realtime_client agrega `type` y `event` al mapa: debe ser mutable.
    await _channel.sendBroadcastMessage(
      event: _endEvent,
      payload: <String, dynamic>{},
    );
  }

  @override
  Future<void> leave() async {
    if (_left) return;
    _left = true;
    await _events.close();
    await _client.removeChannel(_channel);
  }
}
