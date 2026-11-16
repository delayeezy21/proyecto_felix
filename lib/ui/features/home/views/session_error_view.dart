import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

/// Se muestra si la sesión existe pero la cuenta no se pudo cargar: evita que
/// la app quede "pegada" en la pantalla de carga.
class SessionErrorView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: EmptyState(
              icon: Icons.cloud_off,
              isError: true,
              title: 'No pudimos cargar tu cuenta.',
              titleKey: const Key('session-error'),
              message: 'Revisa tu conexión e inténtalo de nuevo.',
              action: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    key: const Key('session-retry'),
                    onPressed: () => ref.invalidate(sessionProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('session-sign-out'),
                    onPressed: () =>
                        ref.read(authControllerProvider.notifier).signOut(),
                    child: const Text('Cerrar sesión'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
