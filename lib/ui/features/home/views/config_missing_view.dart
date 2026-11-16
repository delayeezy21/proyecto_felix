import 'package:flutter/material.dart';
import 'package:proyecto_felix/ui/core/brand.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';

/// Se muestra cuando la app se ejecuta sin `--dart-define-from-file=.env`.
class ConfigMissingView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const BrandHeader(),
                  const SizedBox(height: 32),
                  const InfoBanner(
                    tone: BannerTone.warning,
                    icon: Icons.settings_outlined,
                    message: 'Backend sin configurar (revisa .env)',
                    textKey: Key('backend-status'),
                  ),
                  const SizedBox(height: 16),
                  Text('Ejecuta:', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      'flutter run --dart-define-from-file=.env',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
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
