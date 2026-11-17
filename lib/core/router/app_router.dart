import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/ui/features/admin/views/admin_home_view.dart';
import 'package:proyecto_felix/ui/features/admin/views/admin_vet_review_view.dart';
import 'package:proyecto_felix/ui/features/auth/views/login_view.dart';
import 'package:proyecto_felix/ui/features/auth/views/sign_up_view.dart';
import 'package:proyecto_felix/ui/features/home/views/role_home_view.dart';
import 'package:proyecto_felix/ui/features/home/views/session_error_view.dart';
import 'package:proyecto_felix/ui/features/home/views/splash_view.dart';
import 'package:proyecto_felix/ui/features/onboarding/views/onboarding_view.dart';
import 'package:proyecto_felix/ui/features/owner/views/address_form_view.dart';
import 'package:proyecto_felix/ui/features/owner/views/owner_home_view.dart';
import 'package:proyecto_felix/ui/features/owner/views/pet_form_view.dart';
import 'package:proyecto_felix/ui/features/vet/views/vet_profile_view.dart';

/// Router con protección por sesión y rol (ver `AppRoutes.redirect`).
final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref
    ..listen(sessionProvider, (_, _) => refresh.value++)
    ..onDispose(refresh.dispose);

  SessionSnapshot currentSession() => switch (ref.read(sessionProvider)) {
    AsyncData(:final value) => value,
    AsyncError() => const SessionFailed(),
    _ => const SessionLoading(),
  };

  final router = GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: refresh,
    redirect: (context, state) =>
        AppRoutes.redirect(currentSession(), state.matchedLocation),
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const SplashView(),
      ),
      GoRoute(
        path: AppRoutes.sessionError,
        builder: (context, state) => const SessionErrorView(),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (context, state) => const LoginView(),
      ),
      GoRoute(
        path: AppRoutes.signUp,
        builder: (context, state) => const SignUpView(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        builder: (context, state) => const OnboardingView(),
      ),
      GoRoute(
        path: AppRoutes.owner,
        builder: (context, state) => const OwnerHomeView(),
        routes: [
          GoRoute(
            path: 'pets/new',
            builder: (context, state) => const PetFormView(),
          ),
          GoRoute(
            path: 'pets/:id',
            builder: (context, state) =>
                PetFormView(petId: state.pathParameters['id']),
          ),
          GoRoute(
            path: 'addresses/new',
            builder: (context, state) => const AddressFormView(),
          ),
          GoRoute(
            path: 'addresses/:id',
            builder: (context, state) =>
                AddressFormView(addressId: state.pathParameters['id']),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.vet,
        builder: (context, state) => const VetProfileView(),
        routes: [
          GoRoute(
            path: 'pending',
            builder: (context, state) => const VetProfileView(),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.admin,
        builder: (context, state) => const AdminHomeView(),
        routes: [
          GoRoute(
            path: 'vets/:id',
            builder: (context, state) =>
                AdminVetReviewView(vetId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: AppRoutes.foundation,
        builder: (context, state) => const RoleHomeView(
          title: 'Fundación',
          message: 'Aquí verás los aportes recibidos.',
        ),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
