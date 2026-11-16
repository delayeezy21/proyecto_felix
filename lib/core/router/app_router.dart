import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/ui/features/home/views/home_view.dart';

abstract final class AppRoutes {
  static const home = '/';
}

/// Rutas de la app. La protección por rol se agrega en la fase 1.
final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: AppRoutes.home,
    routes: [
      GoRoute(
        path: AppRoutes.home,
        builder: (context, state) => const HomeView(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
