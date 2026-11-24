import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/core/theme/app_theme.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/catalog_providers.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';
import 'package:proyecto_felix/ui/features/urgent/view_models/urgent_providers.dart';
import 'package:proyecto_felix/ui/features/urgent/views/vet_urgent_card.dart';
import 'package:proyecto_felix/ui/features/vet/view_models/vet_providers.dart';
import 'package:proyecto_felix/ui/features/visits/view_models/visit_providers.dart';

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
            onPressed: () async {
              // Antes de salir: fuera de línea (luego ya no hay sesión).
              await ref.read(vetPresenceProvider.notifier).goOffline();
              await ref.read(authControllerProvider.notifier).signOut();
            },
          ),
        ],
      ),
      body: switch (profile) {
        AsyncData(:final value) => _Body(profile: value),
        AsyncError(:final error) => SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off,
            isError: true,
            title: friendlyError(error),
            action: OutlinedButton.icon(
              onPressed: () => ref.invalidate(vetProfileProvider),
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
              if (profile.status == VetStatus.approved) ...[
                const SizedBox(height: 12),
                const VetUrgentCard(),
                const SizedBox(height: 12),
                const _AgendaCard(),
              ],
              const SizedBox(height: 12),
              _ProfessionalDataCard(profile: profile),
              const SizedBox(height: 12),
              _SpeciesSpecialtiesCard(locked: profile.inReview),
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
  const new({
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                    ),
                    child: Icon(
                      icon,
                      size: 22,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: t.titleMedium),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: t.bodySmall),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color, foreground, title, text) = switch (profile.status) {
      VetStatus.approved => (
        Icons.verified,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        'Perfil verificado',
        'Un administrador revisó tu título e identidad. Ya puedes recibir '
            'solicitudes cuando se habiliten las visitas.',
      ),
      VetStatus.rejected => (
        Icons.error_outline,
        scheme.errorContainer,
        scheme.onErrorContainer,
        'Solicitud rechazada',
        'Motivo: ${profile.rejectionReason ?? '—'}\nCorrige lo indicado y '
            'vuelve a enviarla.',
      ),
      VetStatus.suspended => (
        Icons.block,
        scheme.errorContainer,
        scheme.onErrorContainer,
        'Cuenta suspendida',
        'Contacta al equipo de Felix para más información.',
      ),
      VetStatus.pending when profile.inReview => (
        Icons.hourglass_top,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        'En revisión',
        'Recibimos tu solicitud. Un administrador verificará tu título y tu '
            'identidad; te avisaremos el resultado.',
      ),
      VetStatus.pending => (
        Icons.assignment_outlined,
        scheme.surfaceContainerHighest,
        scheme.onSurface,
        'Completa tu solicitud',
        'Para atender en Felix verificamos que tienes título de Médico '
            'Veterinario válido en Chile. Completa los pasos y envíala.',
      ),
    };
    return Card(
      key: Key('vet-status-${profile.status.name}'),
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.largeRadius),
      ),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(icon, color: foreground, size: 28)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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

enum _SaveState { saved, pending, saving, invalid, error }

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

  /// Guardado automático: antes había que tocar "Guardar" y era fácil
  /// pasarlo por alto (los datos quedaban sin guardar y el envío fallaba).
  Timer? _debounce;
  _SaveState _saveState = _SaveState.saved;

  @override
  void initState() {
    super.initState();
    for (final c in [_university, _year, _code, _bio]) {
      c.addListener(_onEdited);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _university.dispose();
    _year.dispose();
    _code.dispose();
    _bio.dispose();
    super.dispose();
  }

  /// Lo último que efectivamente quedó guardado en la BD. La pantalla se
  /// compara contra esto (no contra el perfil, que se recarga después).
  late _Snapshot _persisted = _Snapshot.fromProfile(widget.profile);

  /// Guardados en curso (puede haber más de uno si el vet sigue editando).
  int _inFlight = 0;

  _Snapshot get _current => _Snapshot(
    bio: _bio.text,
    university: _university.text,
    year: _year.text,
    code: _code.text,
    foreign: _foreign,
  );

  bool get _dirty => !_current.sameAs(
    _persisted,
    professional: widget.profile.canEditProfessionalData,
  );

  bool get _silentlyValid =>
      !widget.profile.canEditProfessionalData ||
      (_university.text.trim().length >= 3 &&
          _validateYear(_year.text) == null);

  /// El envío queda bloqueado mientras lo que se ve no esté guardado: cambios
  /// sin guardar (incluso inválidos), un guardado programado o en curso
  /// (QA-15 y QA-17).
  void _refreshPendingFlag() {
    if (!mounted) return;
    final pending = _dirty || _inFlight > 0 || (_debounce?.isActive ?? false);
    final notifier = ref.read(vetDataDirtyProvider.notifier);
    if (notifier.dirty != pending) notifier.dirty = pending;
  }

  void _onEdited() {
    if (!_dirty) {
      _debounce?.cancel();
      if (_inFlight == 0 && _saveState != _SaveState.saved) {
        setState(() => _saveState = _SaveState.saved);
      }
      _refreshPendingFlag();
      return;
    }
    setState(() => _saveState = _SaveState.pending);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), _autoSave);
    _refreshPendingFlag();
  }

  Future<void> _autoSave() async {
    if (!mounted) return;
    if (!_dirty) {
      if (_inFlight == 0) setState(() => _saveState = _SaveState.saved);
      _refreshPendingFlag();
      return;
    }
    if (!_silentlyValid) {
      // No se guarda y el envío sigue bloqueado: en pantalla hay un dato
      // inválido distinto de lo guardado (QA-17).
      setState(() => _saveState = _SaveState.invalid);
      _refreshPendingFlag();
      return;
    }
    await _persistTracked();
  }

  /// Guarda lo que hay en pantalla y actualiza la instantánea si sale bien.
  Future<bool> _persistTracked({bool rethrowErrors = false}) async {
    final sent = _current;
    _inFlight++;
    setState(() => _saveState = _SaveState.saving);
    _refreshPendingFlag();
    try {
      await _persist(sent);
      if (!mounted) return true;
      _persisted = sent;
      ref.invalidate(vetProfileProvider);
      return true;
    } on Object {
      if (mounted) setState(() => _saveState = _SaveState.error);
      if (rethrowErrors) rethrow;
      return false;
    } finally {
      _inFlight--;
      if (mounted) {
        if (_inFlight == 0 && _saveState != _SaveState.error) {
          setState(
            () => _saveState = _dirty ? _SaveState.pending : _SaveState.saved,
          );
        }
        _refreshPendingFlag();
      }
    }
  }

  Future<void> _persist(_Snapshot s) {
    final repo = ref.read(vetRepositoryProvider);
    return widget.profile.canEditProfessionalData
        ? repo.updateProfessionalData(
            bio: s.bio,
            university: s.university,
            graduationYear: int.tryParse(s.year),
            foreignDegree: s.foreign,
            titleVerificationCode: s.code,
          )
        : repo.updateBio(s.bio);
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
    _debounce?.cancel();
    setState(() => _saving = true);
    await runWithFeedback(
      context,
      () => _persistTracked(rethrowErrors: true),
      success: 'Datos guardados',
    );
    if (mounted) setState(() => _saving = false);
  }

  Widget _saveIndicator(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, text, color) = switch (_saveState) {
      _SaveState.saved => (
        Icons.cloud_done_outlined,
        'Guardado',
        scheme.primary,
      ),
      _SaveState.pending => (Icons.edit_outlined, 'Cambios sin guardar…', null),
      _SaveState.saving => (Icons.cloud_upload_outlined, 'Guardando…', null),
      _SaveState.invalid => (
        Icons.info_outline,
        'Completa universidad y año para guardar',
        scheme.error,
      ),
      _SaveState.error => (
        Icons.error_outline,
        'No se pudo guardar. Toca "Guardar".',
        scheme.error,
      ),
    };
    return Row(
      key: const Key('vet-save-state'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final editable = p.canEditProfessionalData;
    return _Section(
      title: 'Datos profesionales',
      icon: Icons.school_outlined,
      subtitle: editable
          ? 'Deben coincidir con tu certificado de título.'
          : 'Bloqueados mientras están en revisión o tras la verificación.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Text('Nombre profesional: ${p.displayName}'),
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
                onChanged: (v) {
                  setState(() => _foreign = v);
                  _onEdited();
                },
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
                alignLabelWithHint: true,
              ),
            ),
            Row(
              children: [
                Expanded(child: _saveIndicator(context)),
                FilledButton.tonalIcon(
                  key: const Key('vet-save-data'),
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Guardar'),
                ),
              ],
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
  const new({required this.locked});

  /// En revisión no se cambian (el admin revisa lo enviado). QA-12.
  final bool locked;

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
            onSelected: locked
                ? null
                : (on) async {
                    final next = {...selected};
                    on ? next.add(item.id) : next.remove(item.id);
                    await runWithFeedback(
                      context,
                      () => save(next),
                      onDone: refresh,
                    );
                  },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(vetRepositoryProvider);
    final label = Theme.of(context).textTheme.titleSmall;
    return _Section(
      title: 'Especies y especialidades',
      icon: Icons.pets,
      subtitle: locked
          ? 'Bloqueadas mientras tu solicitud está en revisión.'
          : 'Solo recibirás solicitudes que coincidan con lo que marques.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Especies que atiendes', style: label),
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
          Text('Especialidades', style: label),
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
      icon: Icons.calendar_month_outlined,
      subtitle: 'Horarios en que aceptas visitas agendadas.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (blocks.isEmpty)
            const InfoBanner(
              icon: Icons.event_busy_outlined,
              message: 'Aún no defines horarios.',
            )
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
        spacing: 12,
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

class _DocumentsCard extends ConsumerStatefulWidget {
  const new({required this.profile});

  final VetProfile profile;

  @override
  ConsumerState<_DocumentsCard> createState() => _DocumentsCardState();
}

class _DocumentsCardState extends ConsumerState<_DocumentsCard> {
  /// Documento que se está subiendo (muestra un indicador en su fila).
  VetDocumentKind? _uploading;

  Future<void> _upload(VetDocumentKind kind) async {
    final file = await ref.read(documentPickerProvider).pick();
    if (file == null || !mounted) return;
    final error = validateDocument(file);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error, key: const Key('snack-error'))),
      );
      return;
    }
    setState(() => _uploading = kind);
    await runWithFeedback(
      context,
      () => ref.read(vetRepositoryProvider).uploadDocument(kind, file),
      onDone: () => ref.invalidate(vetDocumentsProvider),
      success: '${kind.label}: subido (${file.name})',
    );
    if (mounted) setState(() => _uploading = null);
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final docs = ref.watch(vetDocumentsProvider).value ?? const [];
    final editable = profile.canEditProfessionalData;
    // "Verificados" solo si se purgaron tras una aprobación (QA-14).
    final allVerified =
        docs.isNotEmpty &&
        docs.every((d) => d.isPurged && d.reviewStatus == 'accepted');

    return _Section(
      title: 'Documentos de verificación',
      icon: Icons.folder_outlined,
      subtitle: allVerified
          ? 'Tus documentos ya fueron verificados y eliminados por privacidad.'
          : 'PDF, JPG o PNG de hasta 5 MB. Solo los ve el equipo que verifica '
                'y se eliminan 7 días después de la aprobación '
                '(30 si se rechaza). Los borradores sin enviar se eliminan '
                'a los 90 días.',
      child: Column(
        children: [
          for (final kind in VetDocumentKind.values)
            _DocumentRow(
              kind: kind,
              latest: docs.where((d) => d.kind == kind).firstOrNull,
              editable: editable,
              uploading: _uploading == kind,
              onUpload: _uploading == null ? () => _upload(kind) : null,
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
    this.uploading = false,
  });

  final VetDocumentKind kind;
  final VetDocument? latest;
  final bool editable;
  final bool uploading;

  /// null mientras otro documento se está subiendo.
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    final doc = latest;
    // Eliminado sin verificar (borrador vencido o rechazo): hay que resubir.
    final needsUpload =
        doc == null || (doc.isPurged && doc.reviewStatus != 'accepted');
    final status = switch (doc) {
      null => kind.required ? 'Pendiente' : 'No subido',
      VetDocument(isPurged: true, reviewStatus: 'accepted') =>
        'Verificado y eliminado',
      VetDocument(isPurged: true, reviewStatus: 'rejected') =>
        'Eliminado tras el rechazo: súbelo de nuevo',
      VetDocument(isPurged: true) =>
        'Eliminado por vencimiento (90 días): súbelo de nuevo',
      VetDocument(reviewStatus: 'accepted') => 'Aceptado',
      VetDocument(reviewStatus: 'rejected') => 'Rechazado',
      _ => 'Subido',
    };
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = needsUpload
        ? (Icons.upload_file, scheme.onSurfaceVariant)
        : switch (doc) {
            VetDocument(reviewStatus: 'rejected') => (
              Icons.cancel_outlined,
              scheme.error,
            ),
            _ => (Icons.check_circle, scheme.primary),
          };
    return ListTile(
      key: Key('doc-${kind.dbValue}'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(kind.label),
      subtitle: Text(status, key: Key('doc-status-${kind.dbValue}')),
      trailing: !editable
          ? null
          : uploading
          ? const SizedBox(
              key: Key('uploading'),
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                semanticsLabel: 'Subiendo',
              ),
            )
          : TextButton.icon(
              key: Key('upload-${kind.dbValue}'),
              onPressed: onUpload,
              icon: Icon(
                doc == null ? Icons.file_upload_outlined : Icons.sync,
                size: 18,
              ),
              label: Text(doc == null ? 'Subir' : 'Reemplazar'),
            ),
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
    final savingData = ref.watch(vetDataDirtyProvider);

    return _Section(
      title: 'Declaración y envío',
      icon: Icons.send_outlined,
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
          if (savingData) ...[
            const Text(
              'Tus datos profesionales tienen cambios sin guardar…',
              key: Key('vet-saving-before-submit'),
            ),
            const SizedBox(height: 8),
          ],
          if (missing.isNotEmpty) ...[
            InfoBanner(
              tone: BannerTone.warning,
              icon: Icons.checklist,
              message: 'Te falta: ${missing.join(' · ')}',
              textKey: const Key('vet-missing'),
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            key: const Key('vet-submit'),
            onPressed: missing.isEmpty && !savingData
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

/// Valores editables de los datos profesionales (para comparar pantalla y BD).
class _Snapshot {
  const new({
    required this.bio,
    required this.university,
    required this.year,
    required this.code,
    required this.foreign,
  });

  factory fromProfile(VetProfile p) => _Snapshot(
    bio: p.bio ?? '',
    university: p.university ?? '',
    year: p.graduationYear?.toString() ?? '',
    code: p.titleVerificationCode ?? '',
    foreign: p.foreignDegree,
  );

  final String bio;
  final String university;
  final String year;
  final String code;
  final bool foreign;

  bool sameAs(_Snapshot o, {required bool professional}) {
    String n(String v) => v.trim();
    if (n(bio) != n(o.bio)) return false;
    if (!professional) return true;
    return n(university) == n(o.university) &&
        n(year) == n(o.year) &&
        n(code) == n(o.code) &&
        foreign == o.foreign;
  }
}

// ---------------------------------------------------------------------------
// Agenda: visitas, punto de partida y días libres (solo vets aprobados)
// ---------------------------------------------------------------------------

class _AgendaCard extends ConsumerWidget {
  const new();

  Future<void> _addTimeOff(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final range = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 180)),
      helpText: 'Días libres',
    );
    if (range == null || !context.mounted) return;
    await runWithFeedback(
      context,
      () => ref
          .read(vetAgendaRepositoryProvider)
          .addTimeOff(range.start, range.end),
      onDone: () => ref.invalidate(timeOffProvider),
      success: 'Días libres guardados',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visits = ref.watch(myVisitsProvider).value ?? const <Visit>[];
    final pending = visits
        .where((v) => v.status == VisitStatus.pendingVet)
        .length;
    final base = ref.watch(vetBaseProvider);
    final timeOff = ref.watch(timeOffProvider).value ?? const <TimeOff>[];
    return _Section(
      title: 'Mi agenda',
      icon: Icons.event_note_outlined,
      subtitle: 'Solicitudes, punto de partida y días libres.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          FilledButton.icon(
            key: const Key('vet-open-visits'),
            onPressed: () => context.push(AppRoutes.vetVisits),
            icon: const Icon(Icons.event_available_outlined),
            label: Text(
              pending == 0
                  ? 'Mis visitas'
                  : 'Mis visitas ($pending por confirmar)',
            ),
          ),
          if (base case AsyncData(value: null))
            const InfoBanner(
              key: Key('vet-base-missing'),
              tone: BannerTone.warning,
              message:
                  'Define tu punto de partida para aparecer en las búsquedas '
                  'de los dueños.',
            ),
          OutlinedButton.icon(
            key: const Key('vet-open-base'),
            onPressed: () => context.push(AppRoutes.vetBase),
            icon: const Icon(Icons.my_location_outlined),
            label: const Text('Punto de partida'),
          ),
          const Divider(height: 24),
          Text('Días libres', style: Theme.of(context).textTheme.titleSmall),
          if (timeOff.isEmpty)
            const Text('Sin días libres registrados.')
          else
            for (final t in timeOff)
              ListTile(
                key: Key('time-off-${t.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.beach_access_outlined),
                title: Text(
                  t.from == t.to
                      ? formatDay(t.from)
                      : '${formatDay(t.from)} – ${formatDay(t.to)}',
                ),
                trailing: IconButton(
                  tooltip: 'Quitar',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => runWithFeedback(
                    context,
                    () => ref
                        .read(vetAgendaRepositoryProvider)
                        .removeTimeOff(t.id),
                    onDone: () => ref.invalidate(timeOffProvider),
                  ),
                ),
              ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('add-time-off'),
              icon: const Icon(Icons.add),
              label: const Text('Agregar días libres'),
              onPressed: () => _addTimeOff(context, ref),
            ),
          ),
        ],
      ),
    );
  }
}
