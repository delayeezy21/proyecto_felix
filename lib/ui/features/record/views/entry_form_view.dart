import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/features/record/views/pet_record_view.dart'
    show formatDate;

/// Abre el formulario de una entrada nueva (o de la corrección de
/// [correcting]). Devuelve true si se guardó.
Future<bool> openEntryForm(
  BuildContext context, {
  required String petId,
  required bool ownerMode,
  String? visitId,
  ClinicalEntry? correcting,
}) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => EntryFormView(
        petId: petId,
        visitId: visitId,
        ownerMode: ownerMode,
        correcting: correcting,
      ),
    ),
  );
  return saved ?? false;
}

/// Formulario de entrada. El dueño solo escribe notas; el vet, atenciones,
/// diagnósticos, vacunas y notas. Nada se edita: corregir crea una entrada
/// nueva que reemplaza a la anterior (la anterior queda en el historial).
class EntryFormView extends ConsumerStatefulWidget {
  const new({
    required this.petId,
    required this.ownerMode,
    this.visitId,
    this.correcting,
    super.key,
  });

  final String petId;
  final String? visitId;
  final bool ownerMode;
  final ClinicalEntry? correcting;

  @override
  ConsumerState<EntryFormView> createState() => _EntryFormViewState();
}

class _EntryFormViewState extends ConsumerState<EntryFormView> {
  late EntryKind _kind =
      widget.correcting?.kind ??
      (widget.ownerMode ? EntryKind.note : EntryKind.consultation);
  late final _title = TextEditingController(text: widget.correcting?.title);
  late final _body = TextEditingController(text: widget.correcting?.body);
  late final _vaccine = TextEditingController(
    text: widget.correcting?.vaccine?.name,
  );
  late final _lot = TextEditingController(
    text: widget.correcting?.vaccine?.lot,
  );
  late DateTime _applied = widget.correcting?.vaccine?.appliedOn ?? _today();
  late DateTime? _nextDue = widget.correcting?.vaccine?.nextDue;
  String? _error;
  bool _saving = false;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _vaccine.dispose();
    _lot.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool next}) async {
    final today = _today();
    final picked = await showDatePicker(
      context: context,
      initialDate: next
          ? (_nextDue ?? today.add(const Duration(days: 365)))
          : _applied,
      firstDate: next ? _applied.add(const Duration(days: 1)) : DateTime(2000),
      lastDate: next ? DateTime(today.year + 10) : today,
    );
    if (picked == null) return;
    setState(() => next ? _nextDue = picked : _applied = picked);
  }

  Future<void> _save() async {
    final draft = EntryDraft(
      petId: widget.petId,
      kind: _kind,
      title: _title.text,
      body: _body.text,
      visitId: widget.ownerMode ? null : widget.visitId,
      supersedesId: widget.correcting?.id,
      vaccine: _kind == EntryKind.vaccine
          ? VaccineData(
              name: _vaccine.text,
              lot: _lot.text.trim().isEmpty ? null : _lot.text.trim(),
              appliedOn: _applied,
              nextDue: _nextDue,
            )
          : null,
    );
    final error = validateEntryDraft(draft);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await ref.read(clinicalRepositoryProvider).addEntry(draft);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final correcting = widget.correcting != null;
    final kinds = widget.ownerMode ? const [EntryKind.note] : EntryKind.values;
    return Scaffold(
      appBar: AppBar(
        title: Text(correcting ? 'Corregir entrada' : 'Nueva entrada'),
      ),
      body: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (correcting)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'La ficha no se edita: se guardará una versión nueva y la '
                  'anterior quedará en el historial.',
                ),
              ),
            if (!correcting && kinds.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<EntryKind>(
                  key: const Key('entry-kind'),
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: 'Tipo'),
                  items: [
                    for (final k in kinds)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (k) => setState(() => _kind = k ?? _kind),
                ),
              ),
            TextField(
              key: const Key('entry-title'),
              controller: _title,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Título'),
            ),
            TextField(
              key: const Key('entry-body'),
              controller: _body,
              maxLength: 4000,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Detalle (opcional)',
              ),
            ),
            if (_kind == EntryKind.vaccine) ...[
              TextField(
                key: const Key('entry-vaccine'),
                controller: _vaccine,
                maxLength: 80,
                decoration: const InputDecoration(labelText: 'Vacuna'),
              ),
              TextField(
                key: const Key('entry-lot'),
                controller: _lot,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Lote (opcional)'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Aplicada el'),
                subtitle: Text(formatDate(_applied)),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: () => _pickDate(next: false),
              ),
              ListTile(
                key: const Key('entry-next-due'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Próxima dosis'),
                subtitle: Text(
                  _nextDue == null ? 'Sin fecha' : formatDate(_nextDue!),
                ),
                trailing: const Icon(Icons.event_outlined),
                onTap: () => _pickDate(next: true),
              ),
            ],
            if (_error != null) FormError(_error!),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('entry-save'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Guardando…' : 'Guardar'),
            ),
          ],
        ),
      ),
    );
  }
}
