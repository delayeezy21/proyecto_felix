import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';

final pendingVetApplicationsProvider =
    FutureProvider<List<VetApplicationSummary>>(
      (ref) => ref.watch(vetRepositoryProvider).pendingApplications(),
    );

final FutureProviderFamily<VetApplicationDetail, String>
vetApplicationDetailProvider =
    FutureProvider.family<VetApplicationDetail, String>(
      (ref, id) => ref.watch(vetRepositoryProvider).applicationDetail(id),
    );

String _date(DateTime d) {
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}-${two(l.month)}-${l.year} '
      '${two(l.hour)}:${two(l.minute)}';
}

/// Pestaña con la cola de solicitudes pendientes.
class AdminVetApplicationsTab extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final apps = ref.watch(pendingVetApplicationsProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(pendingVetApplicationsProvider.future),
      child: switch (apps) {
        AsyncData(:final value) when value.isEmpty => ListView(
          children: const [
            SizedBox(height: 48),
            EmptyState(
              icon: Icons.task_alt,
              title: 'No hay solicitudes pendientes.',
              message:
                  'Cuando un veterinario envíe su solicitud aparecerá aquí. '
                  'Desliza hacia abajo para actualizar.',
            ),
          ],
        ),
        AsyncData(:final value) => MaxWidth(
          child: ListView.separated(
            padding: const EdgeInsets.all(8),
            itemCount: value.length,
            separatorBuilder: (_, _) =>
                const Divider(indent: 16, endIndent: 16),
            itemBuilder: (context, i) {
              final a = value[i];
              final scheme = Theme.of(context).colorScheme;
              return ListTile(
                key: Key('application-${a.userId}'),
                leading: CircleAvatar(
                  backgroundColor: scheme.secondaryContainer,
                  foregroundColor: scheme.onSecondaryContainer,
                  child: const Icon(Icons.badge_outlined),
                ),
                title: Text(a.displayName),
                subtitle: Text(
                  '${a.university ?? 'Sin universidad'} · enviada '
                  '${_date(a.submittedAt)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/admin/vets/${a.userId}'),
              );
            },
          ),
        ),
        AsyncError(:final error) => ListView(
          children: [
            const SizedBox(height: 48),
            EmptyState(
              icon: Icons.cloud_off,
              isError: true,
              title: friendlyError(error),
              message: 'Desliza hacia abajo para reintentar.',
            ),
          ],
        ),
        _ => const LoadingView(),
      },
    );
  }
}

/// Revisión de una solicitud: datos, documentos, lista de chequeo y decisión.
class AdminVetReviewView extends ConsumerStatefulWidget {
  const new({required this.vetId, super.key});

  final String vetId;

  @override
  ConsumerState<AdminVetReviewView> createState() => _AdminVetReviewViewState();
}

/// Lista de chequeo del admin (queda en las notas de la revisión).
const _checks = [
  ('name', 'El nombre del título coincide con la cédula', true),
  ('university', 'La universidad está reconocida por el Estado de Chile', true),
  ('code', 'Verifiqué el certificado en el sitio de la universidad', true),
  ('colmevet', 'Aparece en el buscador de colegiados de COLMEVET', false),
];

class _AdminVetReviewViewState extends ConsumerState<AdminVetReviewView> {
  final _checked = <String>{};
  final _notes = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  bool get _requiredChecked =>
      _checks.where((c) => c.$3).every((c) => _checked.contains(c.$1));

  String _composeNotes() {
    final lines = [
      for (final c in _checks)
        '[${_checked.contains(c.$1) ? 'x' : ' '}] ${c.$2}',
      if (_notes.text.trim().isNotEmpty) _notes.text.trim(),
    ];
    return lines.join('\n');
  }

  Future<void> _openDocument(VetDocument doc) async {
    final path = doc.storagePath;
    if (path == null) return;
    await runWithFeedback(context, () async {
      final url = await ref.read(vetRepositoryProvider).documentUrl(path);
      await ref.read(urlOpenerProvider).open(url);
    });
  }

  Future<void> _decide({required bool approve}) async {
    String? reason;
    if (!approve) {
      reason = await _askReason();
      if (reason == null) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      () => ref
          .read(vetRepositoryProvider)
          .review(
            widget.vetId,
            approve: approve,
            reason: reason,
            notes: _composeNotes(),
          ),
      success: approve ? 'Veterinario aprobado' : 'Solicitud rechazada',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref
        ..invalidate(pendingVetApplicationsProvider)
        ..invalidate(vetApplicationDetailProvider(widget.vetId));
      context.go('/admin');
    }
  }

  Future<String?> _askReason() {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Motivo del rechazo'),
        content: Form(
          key: formKey,
          child: TextFormField(
            key: const Key('reject-reason'),
            controller: controller,
            autofocus: true,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              hintText: 'Ej: el nombre del título no coincide con la cédula',
            ),
            validator: (v) =>
                (v?.trim().length ?? 0) < 5 ? 'Explica el motivo' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('reject-confirm'),
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(context).pop(controller.text.trim());
              }
            },
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(vetApplicationDetailProvider(widget.vetId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Revisar solicitud'),
        leading: BackButton(onPressed: () => context.go('/admin')),
      ),
      body: switch (detail) {
        AsyncData(:final value) => _content(context, value),
        AsyncError(:final error) => SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off,
            isError: true,
            title: friendlyError(error),
            action: OutlinedButton.icon(
              onPressed: () =>
                  ref.invalidate(vetApplicationDetailProvider(widget.vetId)),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ),
        ),
        _ => const LoadingView(),
      },
    );
  }

  Widget _content(BuildContext context, VetApplicationDetail d) {
    final p = d.profile;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ReviewSection(
                icon: Icons.person_outline,
                title: p.displayName,
                titleStyle: t.headlineSmall,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 6,
                  children: [
                    Text('Universidad: ${p.university ?? '—'}'),
                    Text('Año de titulación: ${p.graduationYear ?? '—'}'),
                    Text(
                      'Código de verificación: '
                      '${p.titleVerificationCode ?? '—'}',
                    ),
                    if (p.foreignDegree)
                      const Text(
                        'Declara título extranjero revalidado en Chile',
                      ),
                    Text('Especies: ${d.speciesNames.join(', ')}'),
                    Text('Especialidades: ${d.specialtyNames.join(', ')}'),
                    if (p.declarationAcceptedAt != null)
                      Text(
                        'Declaración jurada aceptada el '
                        '${_date(p.declarationAcceptedAt!)}',
                        style: t.bodySmall,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ReviewSection(
                icon: Icons.folder_open_outlined,
                title: 'Documentos',
                child: Column(
                  children: [
                    if (d.documents.isEmpty)
                      Text('Sin documentos.', style: t.bodySmall),
                    for (final doc in d.documents)
                      ListTile(
                        key: Key('review-doc-${doc.kind.dbValue}'),
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          doc.mime == 'application/pdf'
                              ? Icons.picture_as_pdf
                              : Icons.image_outlined,
                        ),
                        title: Text(doc.kind.label),
                        subtitle: Text('Subido ${_date(doc.uploadedAt)}'),
                        trailing: doc.isPurged
                            ? const Text('Eliminado')
                            : TextButton.icon(
                                key: Key('open-${doc.kind.dbValue}'),
                                onPressed: () => _openDocument(doc),
                                icon: const Icon(Icons.open_in_new, size: 18),
                                label: const Text('Ver (60 s)'),
                              ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _ReviewSection(
                icon: Icons.checklist,
                title: 'Lista de chequeo',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'En Chile no hay un registro público oficial de '
                      'veterinarios: verifica el certificado con la '
                      'universidad emisora.',
                      style: t.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    for (final c in _checks)
                      CheckboxListTile(
                        key: Key('check-${c.$1}'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _checked.contains(c.$1),
                        onChanged: (v) => setState(
                          () => v ?? false
                              ? _checked.add(c.$1)
                              : _checked.remove(c.$1),
                        ),
                        title: Text(c.$3 ? c.$2 : '${c.$2} (opcional)'),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('review-notes'),
                      // Checklist ~250 caracteres; la BD admite 1000 (QA-08/QA-18).
                      maxLength: 500,
                      controller: _notes,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Notas internas (opcional)',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('review-reject'),
                      onPressed: _busy ? null : () => _decide(approve: false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                        side: BorderSide(color: scheme.error),
                      ),
                      icon: const Icon(Icons.close),
                      label: const Text('Rechazar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('review-approve'),
                      onPressed: _busy || !_requiredChecked
                          ? null
                          : () => _decide(approve: true),
                      icon: const Icon(Icons.check),
                      label: const Text('Aprobar'),
                    ),
                  ),
                ],
              ),
              if (!_requiredChecked)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Para aprobar, marca los 3 chequeos obligatorios.',
                    style: t.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tarjeta con ícono y título para cada bloque de la revisión.
class _ReviewSection extends StatelessWidget {
  const new({
    required this.icon,
    required this.title,
    required this.child,
    this.titleStyle,
  });

  final IconData icon;
  final String title;
  final TextStyle? titleStyle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: Icon(icon, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: titleStyle ?? theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
