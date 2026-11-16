import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';
import 'package:proyecto_felix/ui/features/vet/view_models/vet_providers.dart';

/// Perfil profesional del vet: solicitud de verificación (pendiente o
/// rechazada) y administración del perfil una vez aprobado.
class VetProfileView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(vetProfileProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          profile.value?.status == VetStatus.approved
              ? 'Mi perfil profesional'
              : 'Verificación profesional',
        ),
        actions: [
          IconButton(
            key: const Key('sign-out'),
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
        ],
      ),
      body: switch (profile) {
        AsyncData(:final value) => _Body(profile: value),
        AsyncError(:final error) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(friendlyError(error)),
              TextButton(
                onPressed: () => ref.invalidate(vetProfileProvider),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const new({required this.profile});

  final VetProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusBanner(profile: profile),
              const SizedBox(height: 12),
              _ProfessionalDataCard(profile: profile),
              const SizedBox(height: 12),
              const _SpeciesSpecialtiesCard(),
              const SizedBox(height: 12),
              const _AvailabilityCard(),
              const SizedBox(height: 12),
              _DocumentsCard(profile: profile),
              if (profile.canEditProfessionalData) ...[
                const SizedBox(height: 12),
                _SubmitCard(profile: profile),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const new({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: t.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: t.bodySmall),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Estado de la solicitud
// ---------------------------------------------------------------------------

class _StatusBanner extends StatelessWidget {
  const new({required this.profile});

  final VetProfile profile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, title, text) = switch (profile.status) {
      VetStatus.approved => (
        Icons.verified,
        scheme.primaryContainer,
        'Perfil verificado',
        'Un administrador revisó tu título e identidad. Ya puedes recibir '
            'solicitudes cuando se habiliten las visitas.',
      ),
      VetStatus.rejected => (
        Icons.error_outline,
        scheme.errorContainer,
        'Solicitud rechazada',
        'Motivo: ${profile.rejectionReason ?? '—'}\nCorrige lo indicado y '
            'vuelve a enviarla.',
      ),
      VetStatus.suspended => (
        Icons.block,
        scheme.errorContainer,
        'Cuenta suspendida',
        'Contacta al equipo de Felix para más información.',
      ),
      VetStatus.pending when profile.inReview => (
        Icons.hourglass_top,
        scheme.secondaryContainer,
        'En revisión',
        'Recibimos tu solicitud. Un administrador verificará tu título y tu '
            'identidad; te avisaremos el resultado.',
      ),
      VetStatus.pending => (
        Icons.assignment_outlined,
        scheme.surfaceContainerHighest,
        'Completa tu solicitud',
        'Para atender en Felix verificamos que tienes título de Médico '
            'Veterinario válido en Chile. Completa los pasos y envíala.',
      ),
    };
    return Card(
      key: Key('vet-status-${profile.status.name}'),
      color: color,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(text),
        isThreeLine: true,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Datos profesionales
// ---------------------------------------------------------------------------

class _ProfessionalDataCard extends ConsumerStatefulWidget {
  const new({required this.profile});

  final VetProfile profile;

  @override
  ConsumerState<_ProfessionalDataCard> createState() =>
      _ProfessionalDataCardState();
}

class _ProfessionalDataCardState extends ConsumerState<_ProfessionalDataCard> {
  final _formKey = GlobalKey<FormState>();
  late final _university = TextEditingController(
    text: widget.profile.university,
  );
  late final _year = TextEditingController(
    text: widget.profile.graduationYear?.toString(),
  );
  late final _code = TextEditingController(
    text: widget.profile.titleVerificationCode,
  );
  late final _bio = TextEditingController(text: widget.profile.bio);
  late bool _foreign = widget.profile.foreignDegree;
  bool _saving = false;

  @override
  void dispose() {
    _university.dispose();
    _year.dispose();
    _code.dispose();
    _bio.dispose();
    super.dispose();
  }

  String? _validateYear(String? v) {
    final y = int.tryParse(v ?? '');
    if (y == null) return 'Ingresa el año (ej: 2015)';
    if (y < 1950 || y > DateTime.now().year) return 'Año no válido';
    return null;
  }

  Future<void> _save() async {
    final editable = widget.profile.canEditProfessionalData;
    if (editable && !(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final repo = ref.read(vetRepositoryProvider);
    await runWithFeedback(
      context,
      () => editable
          ? repo.updateProfessionalData(
              bio: _bio.text,
              university: _university.text,
              graduationYear: int.tryParse(_year.text),
              foreignDegree: _foreign,
              titleVerificationCode: _code.text,
            )
          : repo.updateBio(_bio.text),
      onDone: () => ref.invalidate(vetProfileProvider),
      success: 'Datos guardados',
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final editable = p.canEditProfessionalData;
    return _Section(
      title: 'Datos profesionales',
      subtitle: editable
          ? 'Deben coincidir con tu certificado de título.'
          : 'Bloqueados mientras están en revisión o tras la verificación.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Nombre profesional: ${p.displayName}'),
            const SizedBox(height: 8),
            if (editable) ...[
              TextFormField(
                key: const Key('vet-university'),
                controller: _university,
                decoration: const InputDecoration(
                  labelText: 'Universidad que otorgó el título',
                ),
                validator: (v) => (v?.trim().length ?? 0) < 3
                    ? 'Ingresa la universidad'
                    : null,
              ),
              TextFormField(
                key: const Key('vet-year'),
                controller: _year,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Año de titulación',
                ),
                validator: _validateYear,
              ),
              TextFormField(
                key: const Key('vet-code'),
                controller: _code,
                decoration: const InputDecoration(
                  labelText: 'Código o folio de verificación (opcional)',
                  helperText:
                      'Aparece en el certificado; acelera la verificación',
                ),
              ),
              SwitchListTile(
                key: const Key('vet-foreign'),
                contentPadding: EdgeInsets.zero,
                value: _foreign,
                onChanged: (v) => setState(() => _foreign = v),
                title: const Text('Título extranjero revalidado en Chile'),
              ),
            ] else ...[
              Text('Universidad: ${p.university ?? '—'}'),
              Text('Año de titulación: ${p.graduationYear ?? '—'}'),
              if (p.foreignDegree)
                const Text('Título extranjero revalidado en Chile'),
            ],
            TextFormField(
              key: const Key('vet-bio'),
              controller: _bio,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Presentación para los dueños (opcional)',
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                key: const Key('vet-save-data'),
                onPressed: _saving ? null : _save,
                child: const Text('Guardar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Especies y especialidades
// ---------------------------------------------------------------------------

class _SpeciesSpecialtiesCard extends ConsumerWidget {
  const new();

  Widget _chips(
    BuildContext context,
    WidgetRef ref, {
    required CatalogKind kind,
    required AsyncValue<Set<int>> selectedAsync,
    required Future<void> Function(Set<int>) save,
    required VoidCallback refresh,
  }) {
    final items = ref.watch(catalogItemsProvider(kind)).value ?? const [];
    final selected = selectedAsync.value ?? const <int>{};
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final item in items)
          FilterChip(
            key: Key('chip-${kind.name}-${item.slug}'),
            label: Text(item.name),
            selected: selected.contains(item.id),
            onSelected: (on) async {
              final next = {...selected};
              on ? next.add(item.id) : next.remove(item.id);
              await runWithFeedback(context, () => save(next), onDone: refresh);
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(vetRepositoryProvider);
    return _Section(
      title: 'Especies y especialidades',
      subtitle: 'Solo recibirás solicitudes que coincidan con lo que marques.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Especies que atiendes'),
          const SizedBox(height: 8),
          _chips(
            context,
            ref,
            kind: CatalogKind.species,
            selectedAsync: ref.watch(vetSpeciesProvider),
            save: repo.setSpecies,
            refresh: () => ref.invalidate(vetSpeciesProvider),
          ),
          const SizedBox(height: 16),
          const Text('Especialidades'),
          const SizedBox(height: 8),
          _chips(
            context,
            ref,
            kind: CatalogKind.specialties,
            selectedAsync: ref.watch(vetSpecialtiesProvider),
            save: repo.setSpecialties,
            refresh: () => ref.invalidate(vetSpecialtiesProvider),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Disponibilidad semanal
// ---------------------------------------------------------------------------

class _AvailabilityCard extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocks = ref.watch(vetAvailabilityProvider).value ?? const [];
    final repo = ref.watch(vetRepositoryProvider);
    void refresh() => ref.invalidate(vetAvailabilityProvider);

    return _Section(
      title: 'Disponibilidad semanal',
      subtitle: 'Horarios en que aceptas visitas agendadas.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (blocks.isEmpty)
            const Text('Aún no defines horarios.')
          else
            for (final b in blocks)
              ListTile(
                key: Key('block-${b.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text(
                  '${weekdayNames[b.weekday - 1]} · '
                  '${formatMinutes(b.startMin)}–${formatMinutes(b.endMin)}',
                ),
                trailing: IconButton(
                  tooltip: 'Quitar',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => runWithFeedback(
                    context,
                    () => repo.removeAvailability(b.id),
                    onDone: refresh,
                  ),
                ),
              ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('add-block'),
              icon: const Icon(Icons.add),
              label: const Text('Agregar horario'),
              onPressed: () async {
                final block = await showDialog<(int, int, int)>(
                  context: context,
                  builder: (_) => const _BlockDialog(),
                );
                if (block == null || !context.mounted) return;
                await runWithFeedback(
                  context,
                  () => repo.addAvailability(block.$1, block.$2, block.$3),
                  onDone: refresh,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockDialog extends StatefulWidget {
  const new();

  @override
  State<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<_BlockDialog> {
  int _weekday = 1;
  int _start = 9 * 60;
  int _end = 13 * 60;

  static final List<int> _times = [for (var m = 0; m <= 24 * 60; m += 30) m];

  @override
  Widget build(BuildContext context) {
    final valid = _start < _end;
    return AlertDialog(
      title: const Text('Nuevo horario'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('block-weekday'),
            initialValue: _weekday,
            decoration: const InputDecoration(labelText: 'Día'),
            items: [
              for (var d = 1; d <= 7; d++)
                DropdownMenuItem(value: d, child: Text(weekdayNames[d - 1])),
            ],
            onChanged: (v) => setState(() => _weekday = v ?? 1),
          ),
          DropdownButtonFormField<int>(
            key: const Key('block-start'),
            initialValue: _start,
            decoration: const InputDecoration(labelText: 'Desde'),
            items: [
              for (final m in _times.where((m) => m < 24 * 60))
                DropdownMenuItem(value: m, child: Text(formatMinutes(m))),
            ],
            onChanged: (v) => setState(() => _start = v ?? _start),
          ),
          DropdownButtonFormField<int>(
            key: const Key('block-end'),
            initialValue: _end,
            decoration: const InputDecoration(labelText: 'Hasta'),
            items: [
              for (final m in _times.where((m) => m > 0))
                DropdownMenuItem(value: m, child: Text(formatMinutes(m))),
            ],
            onChanged: (v) => setState(() => _end = v ?? _end),
          ),
          if (!valid)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'La hora de término debe ser posterior al inicio',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('block-save'),
          onPressed: valid
              ? () => Navigator.of(context).pop((_weekday, _start, _end))
              : null,
          child: const Text('Agregar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Documentos
// ---------------------------------------------------------------------------

class _DocumentsCard extends ConsumerWidget {
  const new({required this.profile});

  final VetProfile profile;

  Future<void> _upload(
    BuildContext context,
    WidgetRef ref,
    VetDocumentKind kind,
  ) async {
    final file = await ref.read(documentPickerProvider).pick();
    if (file == null || !context.mounted) return;
    final error = validateDocument(file);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error, key: const Key('snack-error'))),
      );
      return;
    }
    await runWithFeedback(
      context,
      () => ref.read(vetRepositoryProvider).uploadDocument(kind, file),
      onDone: () => ref.invalidate(vetDocumentsProvider),
      success: '${kind.label}: subido',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(vetDocumentsProvider).value ?? const [];
    final editable = profile.canEditProfessionalData;
    final allPurged = docs.isNotEmpty && docs.every((d) => d.isPurged);

    return _Section(
      title: 'Documentos de verificación',
      subtitle: allPurged
          ? 'Tus documentos ya fueron verificados y eliminados por privacidad.'
          : 'PDF, JPG o PNG de hasta 5 MB. Solo los ve el equipo que verifica '
                'y se eliminan 7 días después de la revisión.',
      child: Column(
        children: [
          for (final kind in VetDocumentKind.values)
            _DocumentRow(
              kind: kind,
              latest: docs.where((d) => d.kind == kind).firstOrNull,
              editable: editable,
              onUpload: () => _upload(context, ref, kind),
            ),
        ],
      ),
    );
  }
}

class _DocumentRow extends StatelessWidget {
  const new({
    required this.kind,
    required this.latest,
    required this.editable,
    required this.onUpload,
  });

  final VetDocumentKind kind;
  final VetDocument? latest;
  final bool editable;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final doc = latest;
    final status = switch (doc) {
      null => kind.required ? 'Pendiente' : 'No subido',
      VetDocument(isPurged: true) => 'Verificado y eliminado',
      VetDocument(reviewStatus: 'accepted') => 'Aceptado',
      VetDocument(reviewStatus: 'rejected') => 'Rechazado',
      _ => 'Subido',
    };
    return ListTile(
      key: Key('doc-${kind.dbValue}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        doc == null ? Icons.upload_file : Icons.check_circle,
        color: doc == null ? null : Theme.of(context).colorScheme.primary,
      ),
      title: Text(kind.label),
      subtitle: Text(status, key: Key('doc-status-${kind.dbValue}')),
      trailing: editable
          ? TextButton(
              key: Key('upload-${kind.dbValue}'),
              onPressed: onUpload,
              child: Text(doc == null ? 'Subir' : 'Reemplazar'),
            )
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Declaración jurada y envío
// ---------------------------------------------------------------------------

class _SubmitCard extends ConsumerWidget {
  const new({required this.profile});

  final VetProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(vetRepositoryProvider);
    final missing = missingRequirements(
      profile: profile,
      species: ref.watch(vetSpeciesProvider).value ?? const {},
      specialties: ref.watch(vetSpecialtiesProvider).value ?? const {},
      documents: ref.watch(vetDocumentsProvider).value ?? const [],
    );
    final declared = profile.declarationAcceptedAt != null;

    return _Section(
      title: 'Declaración y envío',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            key: const Key('vet-declaration'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: declared,
            onChanged: declared
                ? null
                : (_) => runWithFeedback(
                    context,
                    repo.acceptDeclaration,
                    onDone: () => ref.invalidate(vetProfileProvider),
                  ),
            title: const Text(declarationText),
          ),
          const SizedBox(height: 8),
          if (missing.isNotEmpty) ...[
            Text(
              'Te falta: ${missing.join(' · ')}',
              key: const Key('vet-missing'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton(
            key: const Key('vet-submit'),
            onPressed: missing.isEmpty
                ? () => runWithFeedback(
                    context,
                    repo.submitApplication,
                    onDone: () => ref.invalidate(vetProfileProvider),
                    success: 'Solicitud enviada a revisión',
                  )
                : null,
            child: Text(
              profile.status == VetStatus.rejected
                  ? 'Reenviar a revisión'
                  : 'Enviar a revisión',
            ),
          ),
        ],
      ),
    );
  }
}
