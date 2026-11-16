import 'package:flutter/material.dart';

/// Se muestra cuando la app se ejecuta sin `--dart-define-from-file=.env`.
class ConfigMissingView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
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
              const Text(
                'Backend sin configurar (revisa .env)',
                key: Key('backend-status'),
              ),
              const SizedBox(height: 8),
              Text(
                'Ejecuta: flutter run --dart-define-from-file=.env',
                style: textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
