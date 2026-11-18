import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

/// Duraciones ofrecidas para una autorización del dueño (máx. 365 días).
const grantDurations = [7, 30, 90];

/// El dueño autoriza a un veterinario que ya lo atendió a ver la ficha de
/// [petId] por un plazo. Devuelve true si se otorgó.
Future<bool> showGrantDialog(BuildContext context, String petId) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _GrantDialog(petId: petId),
    ) ??
    false;

class _GrantDialog extends ConsumerStatefulWidget {
  const new({required this.petId});

  final String petId;

  @override
  ConsumerState<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends ConsumerState<_GrantDialog> {
  String? _vetId;
  int _days = grantDurations.first;
  String? _error;
  bool _saving = false;

  Future<void> _save() async {
    final vetId = _vetId;
    if (vetId == null) {
      setState(() => _error = 'Elige un veterinario.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(clinicalRepositoryProvider)
          .grantAccess(
            petId: widget.petId,
            vetId: vetId,
            until: DateTime.now().add(Duration(days: _days)),
          );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visits = ref.watch(myVisitsProvider);
    // Vets que ya atendieron (o tienen agendada) una visita de esta mascota.
    final vets = <String, String>{
      for (final v in visits.value ?? const <Visit>[])
        if (v.petId == widget.petId && v.vetId != null)
          v.vetId!: v.vetName ?? 'Veterinario',
    };
    return AlertDialog(
      title: const Text('Autorizar a un veterinario'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            const Text(
              'Podrá leer la ficha y descargar adjuntos hasta la fecha que '
              'elijas. No podrá escribir en ella. Puedes revocarlo cuando '
              'quieras.',
            ),
            if (visits.isLoading)
              const LinearProgressIndicator()
            else if (vets.isEmpty)
              const Text(
                'Aún no tienes visitas con veterinarios para esta mascota.',
                key: Key('grant-no-vets'),
              )
            else
              DropdownButtonFormField<String>(
                key: const Key('grant-vet'),
                initialValue: _vetId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Veterinario'),
                items: [
                  for (final e in vets.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _vetId = v),
              ),
            DropdownButtonFormField<int>(
              key: const Key('grant-days'),
              initialValue: _days,
              decoration: const InputDecoration(labelText: 'Por cuánto tiempo'),
              items: [
                for (final d in grantDurations)
                  DropdownMenuItem(value: d, child: Text('$d días')),
              ],
              onChanged: (d) => setState(() => _days = d ?? _days),
            ),
            if (_error != null) FormError(_error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('grant-save'),
          onPressed: _saving || vets.isEmpty ? null : _save,
          child: const Text('Autorizar'),
        ),
      ],
    );
  }
}
