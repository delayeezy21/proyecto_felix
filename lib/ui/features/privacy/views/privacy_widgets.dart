import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/privacy/view_models/privacy_providers.dart';

/// Descarga mis datos y avisa el resultado con un SnackBar.
Future<void> exportMyData(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final name = await ref.read(dataExportProvider.notifier).export();
    if (name == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Listo: guardamos tus datos en $name.',
          key: const Key('export-done'),
        ),
      ),
    );
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(friendlyError(e), key: const Key('snack-error'))),
    );
  }
}

/// Botón "Descargar mis datos" (HU8.1 / HU8.5).
class ExportDataButton extends ConsumerWidget {
  const new({this.buttonKey = const Key('privacy-export'), super.key});

  final Key buttonKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(dataExportProvider).isLoading;
    return OutlinedButton.icon(
      key: buttonKey,
      onPressed: busy ? null : () => exportMyData(context, ref),
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined),
      label: Text(busy ? 'Preparando archivo…' : 'Descargar mis datos'),
    );
  }
}

/// Aviso al iniciar sesión si la política cambió o hay una finalidad opcional
/// nueva (HU8.4). No bloquea: se puede dejar para más tarde.
class PrivacyNoticeBanner extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(noticeDismissedProvider)) return const SizedBox.shrink();
    final status = ref.watch(privacyStatusProvider).value;
    if (status == null) return const SizedBox.shrink();
    final newPurpose = status.purposes.any((p) => p.ask);
    if (!status.mustReview && !newPurpose) return const SizedBox.shrink();
    final message = status.mustReview
        ? 'Actualizamos nuestra política de privacidad '
              '(versión ${status.privacyVersion}). Revisa qué cambió.'
        : 'Hay una nueva finalidad opcional. Tú decides si la aceptas.';
    return Padding(
      key: const Key('privacy-notice'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InfoBanner(
            icon: Icons.policy_outlined,
            title: 'Privacidad',
            message: message,
            liveRegion: true,
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(
                key: const Key('privacy-notice-later'),
                onPressed: () =>
                    ref.read(noticeDismissedProvider.notifier).dismiss(),
                child: const Text('Más tarde'),
              ),
              TextButton(
                key: const Key('privacy-notice-review'),
                onPressed: () => context.push(
                  status.mustReview
                      ? AppRoutes.privacyPolicy
                      : AppRoutes.privacy,
                ),
                child: Text(status.mustReview ? 'Leer la política' : 'Revisar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Vet: entradas clínicas propias retenidas tras el borrado de una cuenta.
/// No se muestra si no hay ninguna.
class RetainedEntriesSection extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(retainedEntriesProvider).value ?? const [];
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      key: const Key('retained-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 40),
        Text(
          'Entradas retenidas',
          style: theme.textTheme.titleMedium,
          semanticsLabel: 'Entradas retenidas',
        ),
        const SizedBox(height: 8),
        Text(
          'Son entradas que escribiste en fichas de cuentas que se borraron. '
          'Se conservan sin datos del dueño hasta la fecha indicada. Para '
          'verlas debes indicar un motivo, que queda registrado.',
          style: theme.textTheme.bodyMedium,
        ),
        for (final e in entries)
          ListTile(
            key: Key('retained-${e.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(
              [
                EntryKind.parse(e.kind).label,
                if (e.species != null) e.species!,
              ].join(' · '),
            ),
            subtitle: Text(
              'Del ${formatLongDate(e.createdAt)}. Se conserva hasta el '
              '${formatLongDate(e.retainUntil)}.',
            ),
            trailing: TextButton(
              key: Key('retained-open-${e.id}'),
              onPressed: () => _open(context, ref, e),
              child: const Text('Consultar'),
            ),
          ),
      ],
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    RetainedEntry entry,
  ) async {
    final detail = await showDialog<RetainedEntryDetail>(
      context: context,
      builder: (_) => _ReasonDialog(entry: entry),
    );
    if (detail == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('retained-detail'),
        title: Text(detail.title ?? EntryKind.parse(detail.kind).label),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                [
                  EntryKind.parse(detail.kind).label,
                  if (detail.species != null) detail.species!,
                  if (detail.specialty != null) detail.specialty!,
                  formatLongDate(detail.createdAt),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (detail.vaccineName != null) ...[
                Text(
                  [
                    'Vacuna: ${detail.vaccineName}',
                    if (detail.vaccineLot != null)
                      '(lote ${detail.vaccineLot})',
                  ].join(' '),
                ),
                const SizedBox(height: 8),
              ],
              Text(detail.body, key: const Key('retained-body')),
              const SizedBox(height: 12),
              Text(
                'Los datos del dueño y de la mascota fueron eliminados.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}

class _ReasonDialog extends ConsumerStatefulWidget {
  const new({required this.entry});

  final RetainedEntry entry;

  @override
  ConsumerState<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends ConsumerState<_ReasonDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final detail = await requestRetainedEntry(
        ref,
        widget.entry.id,
        _reason.text,
      );
      if (mounted) Navigator.of(context).pop(detail);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Motivo de la consulta'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Cuéntanos para qué necesitas esta entrada. El motivo queda '
              'registrado.',
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('retained-reason'),
              controller: _reason,
              maxLength: 500,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Motivo'),
              validator: validateRetainedReason,
            ),
            if (_error != null)
              Text(
                _error!,
                key: const Key('retained-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        key: const Key('retained-submit'),
        onPressed: _busy ? null : _submit,
        child: const Text('Consultar'),
      ),
    ],
  );
}
