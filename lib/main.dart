import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/app.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Env.fromEnvironment();

  if (env.isSupabaseConfigured) {
    await Supabase.initialize(
      url: env.supabaseUrl,
      publishableKey: env.supabasePublishableKey,
    );
  }

  runApp(
    ProviderScope(
      overrides: [envProvider.overrideWithValue(env)],
      child: const FelixApp(),
    ),
  );
}
