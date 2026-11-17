import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/features/admin/view_models/admin_catalog_providers.dart';

/// Gestión de fundaciones: alta, edición, activación y la fundación por
/// defecto. Los miembros (rol `foundation`) se crean por SQL.
class AdminFoundationsTab extends ConsumerWidget {
  const new({super.key});

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action, {
    String? success,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      if (success != null) {
        messenger.showSnackBar(SnackBar(content: Text(success)));
      }
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(catalogErrorMessage(e))));
    } finally {
      ref.invalidate(adminFoundationsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(foundationRepositoryProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-foundation'),
        icon: const Icon(Icons.add),
        label: const Text('Agregar fundación'),
        onPressed: () async {
          final draft = await showDialog<FoundationDraft>(
            context: context,
            builder: (_) => const _FoundationDialog(),
          );
          if (draft == null || !context.mounted) return;
          await _run(
            context,
            ref,
            () => repo.create(draft),
            success: 'Fundación agregada',
          );
        },
      ),
      body: switch (ref.watch(adminFoundationsProvider)) {
        AsyncData(value: final list) when list.isEmpty =>
          const SingleChildScrollView(
            child: EmptyState(
              icon: Icons.volunteer_activism_outlined,
              title: 'Aún no hay fundaciones.',
              message:
                  'Agrega al menos una y márcala como la fundación por '
                  'defecto: sin ella no se puede cotizar.',
            ),
          ),
        AsyncData(value: final list) => MaxWidth(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
            itemCount: list.length,
            separatorBuilder: (_, _) =>
                const Divider(indent: 16, endIndent: 16),
            itemBuilder: (context, i) {
              final f = list[i];
              return ListTile(
                key: Key('foundation-${f.id}'),
                leading: IconButton(
                  key: Key('default-${f.id}'),
                  tooltip: f.isDefault
                      ? 'Fundación por defecto'
                      : 'Marcar como por defecto',
                  icon: Icon(f.isDefault ? Icons.star : Icons.star_border),
                  onPressed: f.isDefault || !f.active
                      ? null
                      : () => _run(
                          context,
                          ref,
                          () => repo.setDefault(f.id),
                          success: '"${f.name}" es la fundación por defecto',
                        ),
                ),
                title: Text(f.name),
                subtitle: Text(
                  [
                    if (f.isDefault) 'Por defecto',
                    if (!f.active) 'Inactiva',
                    ?f.description,
                  ].join(' · '),
                ),
                onTap: () async {
                  final draft = await showDialog<FoundationDraft>(
                    context: context,
                    builder: (_) => _FoundationDialog(initial: f),
                  );
                  if (draft == null || !context.mounted) return;
                  await _run(context, ref, () => repo.update(f.id, draft));
                },
                trailing: Switch(
                  key: Key('active-${f.id}'),
                  value: f.active,
                  onChanged: f.isDefault
                      ? null
                      : (v) => _run(
                          context,
                          ref,
                          () => repo.setActive(f.id, active: v),
                        ),
                ),
              );
            },
          ),
        ),
        AsyncError(:final error) => SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off,
            isError: true,
            title: catalogErrorMessage(error),
            action: OutlinedButton.icon(
              onPressed: () => ref.invalidate(adminFoundationsProvider),
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

class _FoundationDialog extends StatefulWidget {
  const new({this.initial});

  final Foundation? initial;

  @override
  State<_FoundationDialog> createState() => _FoundationDialogState();
}

class _FoundationDialogState extends State<_FoundationDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _description = TextEditingController(
    text: widget.initial?.description,
  );
  late final _website = TextEditingController(text: widget.initial?.website);

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _website.dispose();
    super.dispose();
  }

  static String? _validateWebsite(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return null;
    if (!RegExp(r'^https://\S{3,200}$').hasMatch(t)) {
      return 'Debe comenzar con https://';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.initial == null ? 'Nueva fundación' : 'Editar fundación',
    ),
    content: SizedBox(
      width: 400,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              TextFormField(
                key: const Key('foundation-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nombre'),
                validator: Validators.displayName,
              ),
              TextFormField(
                key: const Key('foundation-description'),
                controller: _description,
                maxLength: 280,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Descripción (opcional)',
                ),
              ),
              TextFormField(
                key: const Key('foundation-website'),
                controller: _website,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Sitio web (opcional)',
                  hintText: 'https://',
                ),
                validator: _validateWebsite,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        key: const Key('foundation-save'),
        onPressed: () {
          if (!(_formKey.currentState?.validate() ?? false)) return;
          Navigator.of(context).pop(
            FoundationDraft(
              name: _name.text,
              description: _description.text,
              website: _website.text,
            ),
          );
        },
        child: const Text('Guardar'),
      ),
    ],
  );
}
