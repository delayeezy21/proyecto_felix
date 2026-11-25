import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';
import 'package:proyecto_felix/ui/features/privacy/view_models/privacy_providers.dart';
import 'package:proyecto_felix/ui/features/privacy/views/privacy_widgets.dart';

/// "Cuenta en proceso de borrado": durante la gracia el titular solo puede
/// cancelar, descargar sus datos o cerrar sesión (arquitectura §8.2).
class AccountBlockedView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(deletionRequestProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cuenta en proceso de borrado'),
        automaticallyImplyLeading: false,
      ),
      body: MaxWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            ...switch (request) {
              AsyncData(value: final r?) when r.isActive => _active(
                context,
                ref,
                r,
              ),
              AsyncData() => [
                const EmptyState(
                  key: Key('blocked-none'),
                  icon: Icons.check_circle_outline,
                  title: 'Tu cuenta ya no tiene un borrado pendiente.',
                ),
                FilledButton(
                  key: const Key('blocked-resume'),
                  onPressed: () =>
                      ref.read(deletionRequestProvider.notifier).resume(),
                  child: const Text('Ir al inicio'),
                ),
              ],
              AsyncError(:final error) => [
                EmptyState(
                  icon: Icons.cloud_off_outlined,
                  title: 'No se pudo cargar el estado del borrado.',
                  message: friendlyError(error),
                  isError: true,
                  action: OutlinedButton.icon(
                    onPressed: () => ref.invalidate(deletionRequestProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ),
              ],
              _ => [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: LoadingView(),
                ),
              ],
            },
            const SizedBox(height: 12),
            const ExportDataButton(buttonKey: Key('blocked-export')),
            const SizedBox(height: 12),
            TextButton.icon(
              key: const Key('blocked-sign-out'),
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).signOut(),
              icon: const Icon(Icons.logout),
              label: const Text('Cerrar sesión'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _active(BuildContext context, WidgetRef ref, DeletionRequest r) {
    final executing = r.status == DeletionStatus.executing || !r.cancellable;
    return [
      InfoBanner(
        tone: BannerTone.warning,
        icon: Icons.lock_clock_outlined,
        title: executing
            ? 'El borrado está en curso'
            : 'Tu cuenta está bloqueada',
        message: executing
            ? 'El plazo para arrepentirse terminó y tus datos se están '
                  'borrando. Aún puedes descargar una copia mientras termine.'
            : 'Pediste borrar tu cuenta. Se borrará el '
                  '${formatLongDateTime(r.executeAfter)}. Hasta entonces '
                  'puedes cancelar el borrado o descargar tus datos.',
        textKey: const Key('blocked-message'),
      ),
      const SizedBox(height: 24),
      if (r.cancellable)
        FilledButton.icon(
          key: const Key('blocked-cancel'),
          onPressed: () => runWithFeedback(
            context,
            () => ref.read(deletionRequestProvider.notifier).cancel(),
            success: 'Cancelaste el borrado. Tu cuenta vuelve a estar activa.',
          ),
          icon: const Icon(Icons.undo),
          label: const Text('Cancelar el borrado'),
        ),
    ];
  }
}
