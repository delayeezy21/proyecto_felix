import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/app.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';

Widget _app(Env env) => ProviderScope(
  overrides: [envProvider.overrideWithValue(env)],
  child: const FelixApp(),
);

void main() {
  testWidgets('la app arranca en la pantalla inicial', (tester) async {
    await tester.pumpWidget(
      _app(
        const Env(
          supabaseUrl: '',
          supabasePublishableKey: '',
          mapProvider: MapProvider.osm,
          mapsApiKey: '',
        ),
      ),
    );

    expect(find.text('Felix'), findsOneWidget);
    expect(find.text('Veterinarios a domicilio'), findsOneWidget);
  });

  testWidgets('avisa cuando el backend no está configurado', (tester) async {
    await tester.pumpWidget(
      _app(
        const Env(
          supabaseUrl: '',
          supabasePublishableKey: '',
          mapProvider: MapProvider.osm,
          mapsApiKey: '',
        ),
      ),
    );

    expect(find.text('Backend sin configurar (revisa .env)'), findsOneWidget);
  });

  testWidgets('indica backend configurado cuando hay url y clave', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Env(
          supabaseUrl: 'http://127.0.0.1:54321',
          supabasePublishableKey: 'clave-de-prueba',
          mapProvider: MapProvider.osm,
          mapsApiKey: '',
        ),
      ),
    );

    expect(find.text('Backend configurado'), findsOneWidget);
  });
}
