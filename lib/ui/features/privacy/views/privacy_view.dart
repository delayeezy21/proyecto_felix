import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/privacy/view_models/privacy_providers.dart';
import 'package:proyecto_felix/ui/features/privacy/views/privacy_widgets.dart';

/// Palabra que el usuario escribe para confirmar el borrado de su cuenta.
const deleteConfirmationWord = 'BORRAR';

/// "Privacidad y datos": descargar mis datos, consentimientos opcionales,
/// política vigente, entradas retenidas (vet) y borrar mi cuenta (fase 11).
class PrivacyView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = switch (ref.watch(sessionProvider).value) {
      SignedIn(:final account?) => account.role,
      _ => null,
    };
    final status = ref.watch(privacyStatusProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacidad y datos')),
      body: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Tus datos', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Descarga una copia de todos los datos que Felix guarda sobre '
              'ti, en un archivo JSON que puedes abrir o llevar a otro '
              'servicio.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            const Align(
              alignment: Alignment.centerLeft,
              child: ExportDataButton(),
            ),
            const Divider(height: 40),
            ...switch (status) {
              AsyncData(:final value) => _statusSections(context, ref, value),
              AsyncError(:final error) => [
                EmptyState(
                  icon: Icons.cloud_off_outlined,
                  title: 'No se pudo cargar tu privacidad.',
                  message: friendlyError(error),
                  isError: true,
                  action: OutlinedButton.icon(
                    onPressed: () => ref.invalidate(privacyStatusProvider),
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
            if (role == AppRole.vet) const RetainedEntriesSection(),
            const Divider(height: 40),
            _DeleteAccountSection(role: role),
          ],
        ),
      ),
    );
  }

  List<Widget> _statusSections(
    BuildContext context,
    WidgetRef ref,
    PrivacyStatus status,
  ) {
    final theme = Theme.of(context);
    return [
      Text('Política de privacidad', style: theme.textTheme.titleMedium),
      ListTile(
        key: const Key('privacy-policy'),
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.article_outlined),
        title: Text('Versión vigente: ${status.privacyVersion}'),
        subtitle: Text(
          status.mustReview
              ? 'Cambió desde la última vez que la viste.'
              : 'Ya la revisaste.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push(AppRoutes.privacyPolicy),
      ),
      const Divider(height: 40),
      Text('Consentimientos opcionales', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      const InfoBanner(
        icon: Icons.location_on_outlined,
        message:
            'La ubicación y los datos necesarios para la atención a domicilio '
            'se usan porque son parte del servicio que contratas, no por '
            'consentimiento. Aquí solo decides lo opcional y puedes cambiarlo '
            'cuando quieras.',
      ),
      const SizedBox(height: 8),
      if (status.purposes.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('No hay finalidades opcionales por ahora.'),
        ),
      for (final p in status.purposes) _ConsentTile(purpose: p),
    ];
  }
}

class _ConsentTile extends ConsumerStatefulWidget {
  const new({required this.purpose});

  final ConsentPurpose purpose;

  @override
  ConsumerState<_ConsentTile> createState() => _ConsentTileState();
}

class _ConsentTileState extends ConsumerState<_ConsentTile> {
  bool _busy = false;

  Future<void> _toggle(bool granted) async {
    final p = widget.purpose;
    if (!granted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('¿Retirar el consentimiento?'),
          content: Text(
            'Dejaremos de usar tus datos para "${p.label}". Queda registrado '
            'y puedes volver a otorgarlo cuando quieras.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              key: const Key('consent-revoke-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Retirar'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _busy = true);
    await runWithFeedback(
      context,
      () => ref
          .read(privacyStatusProvider.notifier)
          .setConsent(p.purpose, granted: granted),
      success: granted
          ? 'Consentimiento otorgado.'
          : 'Consentimiento retirado.',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.purpose;
    final when = switch (p) {
      ConsentPurpose(granted: true, grantedAt: final at?) =>
        'Otorgado el ${formatLongDate(at)}.',
      ConsentPurpose(granted: false, lastRevokedAt: final at?) =>
        'Retirado el ${formatLongDate(at)}.',
      ConsentPurpose(ask: true) => 'Nueva: aún no la respondes.',
      _ => 'No otorgado.',
    };
    return SwitchListTile(
      key: Key('consent-${p.purpose}'),
      contentPadding: EdgeInsets.zero,
      value: p.granted,
      onChanged: _busy ? null : _toggle,
      title: Text(p.label),
      subtitle: Text('${p.description}\n$when'),
      isThreeLine: true,
    );
  }
}

class _DeleteAccountSection extends ConsumerWidget {
  const new({required this.role});

  final AppRole? role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = ref.watch(deletionRequestProvider).isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Borrar mi cuenta', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (role == AppRole.admin)
          const Text('Las cuentas de administración se eliminan por soporte.')
        else ...[
          Text(
            'Tu cuenta se bloquea de inmediato y se borra en 15 días. '
            'Mientras tanto puedes arrepentirte.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('privacy-delete'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: busy ? null : () => _confirm(context, ref),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Borrar mi cuenta'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => DeleteAccountDialog(role: role),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await ref.read(deletionRequestProvider.notifier).request();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(
            'Tu cuenta quedó bloqueada y se borrará el '
            '${formatLongDate(r.executeAfter)}. Si cambias de opinión, '
            'inicia sesión antes de esa fecha y cancela el borrado.',
            key: const Key('delete-requested'),
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(friendlyError(e), key: const Key('snack-error')),
        ),
      );
    }
  }
}

/// Explica qué pasa al borrar la cuenta y pide escribir "BORRAR".
class DeleteAccountDialog extends StatefulWidget {
  const new({this.role, super.key});

  final AppRole? role;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _word = TextEditingController();

  @override
  void initState() {
    super.initState();
    _word.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _word.dispose();
    super.dispose();
  }

  bool get _matches => _word.text.trim() == deleteConfirmationWord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget point(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(child: Text('•  ')),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return AlertDialog(
      title: const Text('¿Borrar tu cuenta?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            point(
              'Tu cuenta se bloquea ahora mismo y se cierra tu sesión. Se '
              'cancelan sin cargo tus visitas pendientes.',
            ),
            point(
              'Tienes 15 días para arrepentirte: inicia sesión y cancela el '
              'borrado. También puedes descargar tus datos.',
            ),
            ...switch (widget.role) {
              AppRole.vet => [
                point(
                  'Después se borran tu perfil, base, horario, documentos, '
                  'consentimientos y dispositivos.',
                ),
                point(
                  'Se retiene sin datos tuyos: las entradas clínicas que '
                  'escribiste quedan firmadas como "MV verificado", y las '
                  'visitas y pagos, anonimizados.',
                ),
              ],
              AppRole.foundation => [
                point(
                  'Después se borran tu membresía, consentimientos y '
                  'dispositivos. Los aportes recibidos por la fundación no '
                  'cambian.',
                ),
              ],
              _ => [
                point(
                  'Después se borran tu perfil, direcciones, mascotas, '
                  'fichas, adjuntos, consentimientos y dispositivos.',
                ),
                point(
                  'Se retiene sin datos tuyos: las entradas clínicas que '
                  'escribieron los veterinarios, por 5 años y sin tu nombre '
                  'ni el de tu mascota; y las visitas y pagos, anonimizados.',
                ),
              ],
            },
            const SizedBox(height: 8),
            Text(
              'Para confirmar, escribe $deleteConfirmationWord.',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('delete-confirm-word'),
              controller: _word,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Escribe $deleteConfirmationWord',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Borrar mi cuenta'),
        ),
      ],
    );
  }
}
