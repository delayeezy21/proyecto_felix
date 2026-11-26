import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/ui/core/app_dropdown.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/quote_providers.dart';

/// Perfil del dueño: por ahora, la fundación que recibe sus aportes.
class OwnerProfileView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = switch (ref.watch(sessionProvider).value) {
      SignedIn(:final account?) => account.displayName,
      _ => '',
    };
    final foundations = ref.watch(foundationsProvider);
    final current = ref.watch(myFoundationIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mi perfil')),
      body: switch ((foundations, current)) {
        (AsyncData(value: final list), AsyncData(value: final id)) => MaxWidth(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (name.isNotEmpty)
                Text(name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              _FoundationChoice(foundations: list, currentId: id),
              const Divider(height: 40),
              ListTile(
                key: const Key('profile-privacy'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.privacy_tip_outlined),
                title: const Text('Privacidad y datos'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.privacy),
              ),
              ListTile(
                key: const Key('profile-about'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.info_outline),
                title: const Text('Acerca de y licencias'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.about),
              ),
            ],
          ),
        ),
        (AsyncError(:final error), _) ||
        (_, AsyncError(:final error)) => SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'No se pudo cargar.',
            message: friendlyError(error),
            isError: true,
            action: OutlinedButton.icon(
              onPressed: () => ref
                ..invalidate(foundationsProvider)
                ..invalidate(myFoundationIdProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ),
        ),
        _ => const LoadingView(),
      },
    );
  }
}

class _FoundationChoice extends ConsumerStatefulWidget {
  const new({required this.foundations, required this.currentId});

  final List<Foundation> foundations;
  final String? currentId;

  @override
  ConsumerState<_FoundationChoice> createState() => _FoundationChoiceState();
}

class _FoundationChoiceState extends ConsumerState<_FoundationChoice> {
  late String? _selected =
      widget.foundations.any((f) => f.id == widget.currentId)
      ? widget.currentId
      : null;

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref
        .read(foundationChoiceProvider.notifier)
        .choose(_selected);
    if (!mounted) return;
    final state = ref.read(foundationChoiceProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Fundación guardada' : friendlyError(state.error ?? Exception()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final saving = ref.watch(foundationChoiceProvider).isLoading;
    final defaultName = widget.foundations
        .where((f) => f.isDefault)
        .map((f) => f.name)
        .firstOrNull;
    final selected = widget.foundations
        .where((f) => f.id == _selected)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text(
          'Fundación que apoyas',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const InfoBanner(
          icon: Icons.volunteer_activism_outlined,
          message:
              'El 20 % de la comisión de cada visita y tus donaciones extra '
              'van a esta fundación. Ella solo ve totales: nunca tu nombre ni '
              'tus datos.',
        ),
        AppDropdown<String?>(
          key: const Key('profile-foundation'),
          initialValue: _selected,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Fundación'),
          items: [
            DropdownMenuItem<String?>(
              child: Text(
                defaultName == null
                    ? 'La fundación por defecto'
                    : 'Por defecto ($defaultName)',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final f in widget.foundations)
              DropdownMenuItem<String?>(
                value: f.id,
                child: Text(f.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _selected = v),
        ),
        if (selected?.description case final d?) Text(d),
        FilledButton.icon(
          key: const Key('profile-foundation-save'),
          onPressed: saving || _selected == widget.currentId ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Guardar'),
        ),
      ],
    );
  }
}
