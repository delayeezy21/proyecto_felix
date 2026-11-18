import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';
import 'package:proyecto_felix/domain/models/visit.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/record/view_models/record_providers.dart';
import 'package:proyecto_felix/ui/features/record/views/entry_form_view.dart';
import 'package:proyecto_felix/ui/features/record/views/grant_dialog.dart';

/// "12-03-2027".
String formatDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.year}';

/// Aviso para el vet: por qué vía accede, hasta cuándo y que se registra.
String vetAccessMessage(PetRecord record) {
  final via = record.accessVia == 'owner_grant'
      ? 'Acceso autorizado por el dueño'
      : 'Acceso por tu visita';
  final until = record.accessUntil == null
      ? 'mientras la visita esté activa'
      : 'hasta el ${formatSlot(record.accessUntil!)}';
  final mode = record.canWrite ? '' : ' Solo lectura.';
  return '$via $until. Cada lectura queda registrada y el dueño puede verla.'
      '$mode';
}

/// Ficha clínica de una mascota. La usan el dueño (completa, con
/// autorizaciones y "Quién vio mi ficha") y el vet desde su visita (solo vía
/// `get_pet_record`, que registra la lectura).
class PetRecordView extends ConsumerWidget {
  const new({required this.petId, this.visitId, super.key});

  final String petId;

  /// Visita del vet (null para el dueño).
  final String? visitId;

  RecordKey get _key => (petId: petId, visitId: visitId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref.watch(petRecordProvider(_key));
    final owner = record.value?.isOwnerView ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          record.value == null
              ? 'Ficha clínica'
              : 'Ficha de ${record.value!.pet.name}',
        ),
        actions: [
          if (owner)
            IconButton(
              key: const Key('record-log'),
              tooltip: 'Quién vio mi ficha',
              icon: const Icon(Icons.visibility_outlined),
              onPressed: () => context.push(AppRoutes.ownerPetRecordLog(petId)),
            ),
        ],
      ),
      floatingActionButton: (record.value?.canWrite ?? false)
          ? FloatingActionButton.extended(
              key: const Key('record-add'),
              onPressed: () => _openForm(context, ref, record.value!),
              icon: const Icon(Icons.add),
              label: Text(owner ? 'Agregar nota' : 'Agregar entrada'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(petRecordProvider(_key).future),
        child: switch (record) {
          AsyncData(:final value) => _Body(record: value, recordKey: _key),
          AsyncError(:final error) => ListView(
            children: [
              EmptyState(
                key: const Key('record-error'),
                icon: Icons.lock_outline,
                title: 'No puedes ver esta ficha.',
                message: friendlyError(error),
                isError: true,
                action: OutlinedButton.icon(
                  onPressed: () => ref.invalidate(petRecordProvider(_key)),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ),
            ],
          ),
          _ => const LoadingView(),
        },
      ),
    );
  }

  Future<void> _openForm(
    BuildContext context,
    WidgetRef ref,
    PetRecord record, {
    ClinicalEntry? correcting,
  }) async {
    final saved = await openEntryForm(
      context,
      petId: petId,
      visitId: visitId,
      ownerMode: record.isOwnerView,
      correcting: correcting,
    );
    if (saved) ref.invalidate(petRecordProvider(_key));
  }
}

class _Body extends ConsumerWidget {
  const new({required this.record, required this.recordKey});

  final PetRecord record;
  final RecordKey recordKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final histories = record.histories;
    final vaccines = record.vaccines;
    final pet = record.pet;
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(text, style: t.titleMedium),
    );
    return MaxWidth(
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              [
                ?pet.speciesName,
                ?pet.breedName,
                if (pet.microchip != null) 'Microchip ${pet.microchip}',
              ].join(' · '),
              key: const Key('record-pet'),
            ),
          ),
          if (!record.isOwnerView)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: InfoBanner(
                key: const Key('record-access'),
                icon: Icons.shield_outlined,
                message: vetAccessMessage(record),
              ),
            ),
          if (record.isOwnerView)
            _GrantsSection(record: record, recordKey: recordKey),
          header('Vacunas'),
          if (vaccines.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Sin vacunas registradas.'),
            )
          else
            for (final v in vaccines)
              ListTile(
                key: Key('record-vaccine-${v.id}'),
                leading: const Icon(Icons.vaccines_outlined),
                title: Text(v.vaccine!.name),
                subtitle: Text(
                  [
                    'Aplicada el ${formatDate(v.vaccine!.appliedOn)}',
                    if (v.vaccine!.nextDue != null)
                      'próxima dosis: ${formatDate(v.vaccine!.nextDue!)}',
                    if (v.vaccine!.lot != null) 'lote ${v.vaccine!.lot}',
                  ].join(' · '),
                ),
              ),
          header('Historial'),
          if (histories.isEmpty)
            const EmptyState(
              key: Key('record-empty'),
              icon: Icons.description_outlined,
              title: 'La ficha aún no tiene entradas.',
            )
          else
            for (final h in histories)
              _EntryCard(history: h, record: record, recordKey: recordKey),
        ],
      ),
    );
  }
}

class _EntryCard extends ConsumerWidget {
  const new({
    required this.history,
    required this.record,
    required this.recordKey,
  });

  final EntryHistory history;
  final PetRecord record;
  final RecordKey recordKey;

  Future<void> _attach(BuildContext context, WidgetRef ref) async {
    final file = await ref.read(documentPickerProvider).pick();
    if (file == null || !context.mounted) return;
    await runWithFeedback(
      context,
      () => ref
          .read(clinicalRepositoryProvider)
          .attach(
            petId: record.pet.id,
            entryId: history.current.id,
            file: file,
          ),
      onDone: () => ref.invalidate(petRecordProvider(recordKey)),
      success: 'Adjunto agregado.',
    );
  }

  Future<void> _correct(BuildContext context, WidgetRef ref) async {
    final saved = await openEntryForm(
      context,
      petId: record.pet.id,
      visitId: recordKey.visitId,
      ownerMode: record.isOwnerView,
      correcting: history.current,
    );
    if (saved) ref.invalidate(petRecordProvider(recordKey));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = history.current;
    final canEdit = record.canWrite && e.mine;
    return Card(
      key: Key('record-entry-${e.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            _EntryContent(entry: e),
            if (e.attachments.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final a in e.attachments)
                    ActionChip(
                      key: Key('record-attachment-${a.id}'),
                      avatar: Icon(
                        a.mime == 'application/pdf'
                            ? Icons.picture_as_pdf_outlined
                            : Icons.image_outlined,
                        size: 18,
                      ),
                      label: Text(a.fileName),
                      onPressed: () => openAttachment(context, ref, a),
                    ),
                ],
              ),
            if (history.wasCorrected)
              ExpansionTile(
                key: Key('record-history-${e.id}'),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  history.previous.length == 1
                      ? 'Corregida · 1 versión anterior'
                      : 'Corregida · ${history.previous.length} '
                            'versiones anteriores',
                ),
                children: [
                  for (final p in history.previous)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Opacity(
                        opacity: 0.75,
                        child: _EntryContent(entry: p, superseded: true),
                      ),
                    ),
                ],
              ),
            if (canEdit)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: Key('record-correct-${e.id}'),
                    onPressed: () => _correct(context, ref),
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Corregir'),
                  ),
                  if (e.attachments.length < 5)
                    OutlinedButton.icon(
                      key: Key('record-attach-${e.id}'),
                      onPressed: () => _attach(context, ref),
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Adjuntar'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _EntryContent extends StatelessWidget {
  const new({required this.entry, this.superseded = false});

  final ClinicalEntry entry;
  final bool superseded;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final e = entry;
    final author = e.byOwner
        ? 'Aportado por el dueño'
        : (e.authorName ?? 'Veterinario');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              label: Text(e.kind.label),
              visualDensity: VisualDensity.compact,
            ),
            Text(formatSlot(e.createdAt), style: t.bodySmall),
            if (superseded) Text('Reemplazada', style: t.labelSmall),
          ],
        ),
        Text(e.title, style: t.titleSmall),
        if ((e.body ?? '').isNotEmpty) Text(e.body!),
        if (e.vaccine != null)
          Text(
            [
              e.vaccine!.name,
              'aplicada el ${formatDate(e.vaccine!.appliedOn)}',
              if (e.vaccine!.nextDue != null)
                'próxima dosis ${formatDate(e.vaccine!.nextDue!)}',
            ].join(' · '),
          ),
        Text([author, ?e.specialtyName].join(' · '), style: t.bodySmall),
      ],
    );
  }
}

/// Pide la URL firmada (60 s) y la abre con un toque nuevo: Safari de iPhone
/// bloquea las ventanas que no nacen directo de un gesto del usuario.
Future<void> openAttachment(
  BuildContext context,
  WidgetRef ref,
  EntryAttachment attachment,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final Uri url;
  try {
    url = await ref
        .read(clinicalRepositoryProvider)
        .attachmentUrl(attachment.id);
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(friendlyError(e), key: const Key('snack-error'))),
    );
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(attachment.fileName),
      content: const Text('El enlace es privado y vence en 60 segundos.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
        FilledButton(
          key: const Key('attachment-open'),
          onPressed: () {
            // Sin await antes de abrir: la ventana nace del toque.
            unawaited(ref.read(urlOpenerProvider).open(url.toString()));
            Navigator.of(context).pop();
          },
          child: const Text('Abrir'),
        ),
      ],
    ),
  );
}

class _GrantsSection extends ConsumerWidget {
  const new({required this.record, required this.recordKey});

  final PetRecord record;
  final RecordKey recordKey;

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    RecordGrant g,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Revocar el acceso?'),
        content: Text('${g.vetName} dejará de ver la ficha de inmediato.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Volver'),
          ),
          FilledButton(
            key: const Key('grant-revoke-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revocar'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runWithFeedback(
      context,
      () => ref.read(clinicalRepositoryProvider).revokeGrant(g.id),
      onDone: () => ref.invalidate(petRecordProvider(recordKey)),
      success: 'Acceso revocado.',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final active = record.grants.where((g) => g.active).toList();
    final past = record.grants.where((g) => !g.active).toList();
    String until(RecordGrant g) => g.expiresAt == null
        ? 'mientras la visita esté activa'
        : 'hasta el ${formatSlot(g.expiresAt!)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Quién tiene acceso', style: t.titleMedium),
              OutlinedButton.icon(
                key: const Key('grant-add'),
                onPressed: () async {
                  final ok = await showGrantDialog(context, record.pet.id);
                  if (ok) ref.invalidate(petRecordProvider(recordKey));
                },
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Autorizar veterinario'),
              ),
            ],
          ),
        ),
        if (active.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Nadie más que tú. El veterinario de cada visita accede desde '
              'que la acepta hasta 30 días después de completarla.',
            ),
          ),
        for (final g in active)
          ListTile(
            key: Key('grant-${g.id}'),
            leading: Icon(
              g.fromVisit
                  ? Icons.event_available
                  : Icons.verified_user_outlined,
            ),
            title: Text(g.vetName),
            subtitle: Text(
              '${g.fromVisit ? 'Por una visita' : 'Autorizado por ti'}, '
              '${until(g)}',
            ),
            trailing: g.canRevoke
                ? TextButton(
                    key: Key('grant-revoke-${g.id}'),
                    onPressed: () => _revoke(context, ref, g),
                    child: const Text('Revocar'),
                  )
                : null,
          ),
        if (past.isNotEmpty)
          ExpansionTile(
            key: const Key('grants-past'),
            title: Text('Accesos terminados (${past.length})'),
            children: [
              for (final g in past)
                ListTile(
                  dense: true,
                  title: Text(g.vetName),
                  subtitle: Text(switch ((g.revokedAt, g.expiresAt)) {
                    (final DateTime r, _) => 'Revocado el ${formatSlot(r)}',
                    (_, final DateTime e) => 'Venció el ${formatSlot(e)}',
                    _ => 'Terminado',
                  }),
                ),
            ],
          ),
      ],
    );
  }
}
