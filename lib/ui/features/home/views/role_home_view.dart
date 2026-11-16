import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

/// Pantalla de inicio provisoria por rol (se reemplaza en fases siguientes).
class RoleHomeView extends ConsumerWidget {
  const new({required this.title, required this.message, super.key});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final name = switch (session) {
      SignedIn(:final account?) => account.displayName,
      _ => '',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            key: const Key('sign-out'),
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (name.isNotEmpty)
                Text(
                  'Hola, $name',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
