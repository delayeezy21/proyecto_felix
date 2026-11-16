import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/core/router/app_router.dart';
import 'package:proyecto_felix/core/theme/app_theme.dart';
import 'package:proyecto_felix/ui/features/home/views/config_missing_view.dart';

class FelixApp extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(envProvider).isSupabaseConfigured) {
      return MaterialApp(
        title: 'Felix',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        debugShowCheckedModeBanner: false,
        home: const ConfigMissingView(),
      );
    }
    return MaterialApp.router(
      title: 'Felix',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: ref.watch(appRouterProvider),
      debugShowCheckedModeBanner: false,
    );
  }
}
