import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';

/// Aviso solo en desarrollo: con Supabase local los correos no llegan a la
/// bandeja real, quedan en Mailpit (en el PC que corre Supabase).
class DevMailHint extends ConsumerWidget {
  const new({super.key});

  static const mailpitUrl = 'http://127.0.0.1:54324';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(envProvider).isLocalBackend) return const SizedBox.shrink();
    return const InfoBanner(
      key: Key('dev-mail-hint'),
      tone: BannerTone.warning,
      icon: Icons.developer_mode,
      title: 'Modo desarrollo',
      message:
          'Los correos no salen a internet. Ábrelos en Mailpit desde el PC: '
          '$mailpitUrl',
    );
  }
}
