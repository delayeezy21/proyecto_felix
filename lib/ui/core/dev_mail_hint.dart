import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';

/// Aviso solo en desarrollo: con Supabase local los correos no llegan a la
/// bandeja real, quedan en Mailpit (en el PC que corre Supabase).
class DevMailHint extends ConsumerWidget {
  const new({super.key});

  static const mailpitUrl = 'http://127.0.0.1:54324';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(envProvider).isLocalBackend) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('dev-mail-hint'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Modo desarrollo: los correos no salen a internet. Ábrelos en '
        'Mailpit desde el PC: $mailpitUrl',
        style: TextStyle(color: scheme.onTertiaryContainer),
      ),
    );
  }
}
