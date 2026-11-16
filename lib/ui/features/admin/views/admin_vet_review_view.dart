import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
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
            SizedBox(height: 80),
            Center(child: Text('No hay solicitudes pendientes.')),
          ],
        ),
        AsyncData(:final value) => ListView.separated(
          itemCount: value.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final a = value[i];
            return ListTile(
              key: Key('application-${a.userId}'),
              leading: const Icon(Icons.badge_outlined),
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
        AsyncError(:final error) => ListView(
          children: [
            const SizedBox(height: 80),
            Center(child: Text(friendlyError(error))),
          ],
        ),
        _ => const Center(child: CircularProgressIndicator()),
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
        AsyncError(:final error) => Center(child: Text(friendlyError(error))),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _content(BuildContext context, VetApplicationDetail d) {
    final p = d.profile;
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(p.displayName, style: t.headlineSmall),
              const SizedBox(height: 8),
              Text('Universidad: ${p.university ?? '—'}'),
              Text('Año de titulación: ${p.graduationYear ?? '—'}'),
              Text('Código de verificación: ${p.titleVerificationCode ?? '—'}'),
              if (p.foreignDegree)
                const Text('Declara título extranjero revalidado en Chile'),
              Text('Especies: ${d.speciesNames.join(', ')}'),
              Text('Especialidades: ${d.specialtyNames.join(', ')}'),
              if (p.declarationAcceptedAt != null)
                Text(
                  'Declaración jurada aceptada el '
                  '${_date(p.declarationAcceptedAt!)}',
                ),
              const Divider(height: 32),
              Text('Documentos', style: t.titleMedium),
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
                      : TextButton(
                          key: Key('open-${doc.kind.dbValue}'),
                          onPressed: () => _openDocument(doc),
                          child: const Text('Ver (60 s)'),
                        ),
                ),
              const Divider(height: 32),
              Text('Lista de chequeo', style: t.titleMedium),
              Text(
                'En Chile no hay un registro público oficial de veterinarios: '
                'verifica el certificado con la universidad emisora.',
                style: t.bodySmall,
              ),
              for (final c in _checks)
                CheckboxListTile(
                  key: Key('check-${c.$1}'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _checked.contains(c.$1),
                  onChanged: (v) => setState(
                    () =>
                        v ?? false ? _checked.add(c.$1) : _checked.remove(c.$1),
                  ),
                  title: Text(c.$3 ? c.$2 : '${c.$2} (opcional)'),
                ),
              TextField(
                key: const Key('review-notes'),
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notas internas (opcional)',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('review-reject'),
                      onPressed: _busy ? null : () => _decide(approve: false),
                      child: const Text('Rechazar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('review-approve'),
                      onPressed: _busy || !_requiredChecked
                          ? null
                          : () => _decide(approve: true),
                      child: const Text('Aprobar'),
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
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
