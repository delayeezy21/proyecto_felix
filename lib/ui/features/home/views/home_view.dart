import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';

/// Pantalla inicial provisoria de la fase 0.
class HomeView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final env = ref.watch(envProvider);
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Felix', style: textTheme.displaySmall),
              const SizedBox(height: 8),
              Text('Veterinarios a domicilio', style: textTheme.titleMedium),
              const SizedBox(height: 24),
              Text(
                env.isSupabaseConfigured
                    ? 'Backend configurado'
                    : 'Backend sin configurar (revisa .env)',
                key: const Key('backend-status'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
