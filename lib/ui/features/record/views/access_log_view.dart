import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/clinical.dart';
import 'package:proyecto_felix/domain/models/visit.dart' show formatSlot;
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/record/view_models/record_providers.dart';

/// "Quién vio mi ficha": cada lectura, descarga, escritura, autorización y
/// revocación de la ficha de una mascota (solo el dueño).
class AccessLogView extends ConsumerWidget {
  const new({required this.petId, super.key});

  final String petId;

  IconData _icon(AccessLogItem i) => switch (i.action) {
    'view' => Icons.visibility_outlined,
    'download' => Icons.download_outlined,
    'create' || 'correct' => Icons.edit_note,
    'grant' => Icons.person_add_alt,
    'revoke' => Icons.person_remove_outlined,
    _ => Icons.history,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(accessLogProvider(petId));
    return Scaffold(
      appBar: AppBar(title: const Text('Quién vio mi ficha')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(accessLogProvider(petId).future),
        child: switch (log) {
          AsyncData(:final value) => MaxWidth(
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Cada vez que un veterinario lee la ficha o descarga un '
                    'adjunto queda registrado aquí. Tus propias lecturas no '
                    'se registran.',
                  ),
                ),
                if (value.isEmpty)
                  const EmptyState(
                    key: Key('access-log-empty'),
                    icon: Icons.visibility_off_outlined,
                    title: 'Nadie ha visto ni modificado la ficha.',
                  ),
                for (final (i, item) in value.indexed)
                  ListTile(
                    key: Key('access-log-$i'),
                    leading: Icon(_icon(item)),
                    title: Text('${item.actorName} ${item.actionLabel}'),
                    subtitle: Text(
                      [
                        formatSlot(item.at),
                        item.viaLabel,
                      ].where((s) => s.isNotEmpty).join(' · '),
                    ),
                  ),
              ],
            ),
          ),
          AsyncError(:final error) => ListView(
            children: [
              EmptyState(
                icon: Icons.cloud_off_outlined,
                title: 'No se pudo cargar.',
                message: friendlyError(error),
                isError: true,
              ),
            ],
          ),
          _ => const LoadingView(),
        },
      ),
    );
  }
}
