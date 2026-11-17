import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/attributions.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';

/// "Acerca de / licencias": atribución de los datos de terceros (CC BY 3.0
/// IGO, ODbL) y las licencias de los paquetes de código abierto.
class AboutView extends ConsumerWidget {
  const new({super.key});

  static const appVersion = '0.1.0';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Acerca de y licencias')),
      body: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Felix', style: theme.textTheme.headlineSmall),
            const Text(
              'Veterinarios a domicilio. Versión $appVersion '
              '(pagos simulados).',
            ),
            const SizedBox(height: 24),
            Text('Datos de terceros', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final a in dataAttributions)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(a.title, style: theme.textTheme.titleSmall),
                      Text(a.usage),
                      Text(
                        a.source,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          key: Key('license-${a.title}'),
                          onPressed: () =>
                              ref.read(urlOpenerProvider).open(a.licenseUrl),
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text('Licencia ${a.license}'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const Key('about-oss-licenses'),
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Felix',
                applicationVersion: appVersion,
              ),
              icon: const Icon(Icons.description_outlined),
              label: const Text('Licencias de código abierto'),
            ),
          ],
        ),
      ),
    );
  }
}
