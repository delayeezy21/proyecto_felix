import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/services/live_location_service.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/urgent.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // QA-F8-01: realtime_client escribe `type` y `event` en el payload. Sin
  // conexión (puerto cerrado) cae al envío REST, que falla sin lanzar: así el
  // test solo detecta el "Cannot modify unmodifiable map" de un mapa `const`.
  late SupabaseClient client;
  late LiveLocationSession session;

  setUp(() {
    client = SupabaseClient('http://127.0.0.1:1', 'test-key');
    session = SupabaseLiveLocationService(client).join('visit-1');
  });

  tearDown(() async {
    await session.leave();
    await client.dispose();
  });

  test(
    'sendEnd no lanza aunque realtime_client modifique el payload',
    () async {
      await expectLater(session.sendEnd(), completes);
    },
  );

  test('send no lanza aunque realtime_client modifique el payload', () async {
    await expectLater(
      session.send(
        LiveLocation(
          const GeoPoint(-33.45, -70.66),
          DateTime.utc(2026, 11, 24, 12),
        ),
      ),
      completes,
    );
  });
}
