import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/core/router/app_router.dart';
import 'package:proyecto_felix/core/theme/app_theme.dart';
import 'package:proyecto_felix/ui/features/home/views/config_missing_view.dart';

/// La app está en español: el calendario, los textos de Material y los
/// formatos usan el español del dispositivo (es-CL por defecto, con la semana
/// de lunes a domingo).
const appLocalizationsDelegates = <LocalizationsDelegate<Object>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];
const appSupportedLocales = [Locale('es', 'CL'), Locale('es')];

/// Usa la variante de español del usuario si la hay; si no, es-CL.
Locale resolveAppLocale(Locale? device, Iterable<Locale> supported) =>
    device?.languageCode == 'es' && device?.countryCode != null
    ? Locale('es', device!.countryCode)
    : const Locale('es', 'CL');

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
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: appSupportedLocales,
        localeResolutionCallback: resolveAppLocale,
        home: const ConfigMissingView(),
      );
    }
    return MaterialApp.router(
      title: 'Felix',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: ref.watch(appRouterProvider),
      debugShowCheckedModeBanner: false,
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: appSupportedLocales,
      localeResolutionCallback: resolveAppLocale,
    );
  }
}
