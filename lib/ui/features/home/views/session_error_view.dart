import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

/// Se muestra si la sesión existe pero la cuenta no se pudo cargar: evita que
/// la app quede "pegada" en la pantalla de carga.
class SessionErrorView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 16),
              const Text(
                'No pudimos cargar tu cuenta.',
                key: Key('session-error'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Revisa tu conexión e inténtalo de nuevo.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('session-retry'),
                onPressed: () => ref.invalidate(sessionProvider),
                child: const Text('Reintentar'),
              ),
              const SizedBox(height: 12),
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
    );
  }
}
