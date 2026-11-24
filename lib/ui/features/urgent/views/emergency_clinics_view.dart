import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/urgent/view_models/urgent_providers.dart';

/// Clínicas 24 h activas, primero las de la comuna de la urgencia.
class EmergencyClinicsView extends ConsumerWidget {
  const new({this.communeName, super.key});

  final String? communeName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clinics = ref.watch(emergencyClinicsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Clínicas 24 h')),
      body: switch (clinics) {
        AsyncData(:final value) when value.isEmpty => const EmptyState(
          key: Key('clinics-empty'),
          icon: Icons.local_hospital_outlined,
          title: 'No hay clínicas 24 h registradas.',
        ),
        AsyncData(:final value) => MaxWidth(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [for (final c in _sorted(value)) _ClinicTile(clinic: c)],
          ),
        ),
        AsyncError(:final error) => SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'No se pudo cargar.',
            message: friendlyError(error),
            isError: true,
            action: OutlinedButton.icon(
              onPressed: () => ref.invalidate(emergencyClinicsProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ),
        ),
        _ => const LoadingView(),
      },
    );
  }

  List<EmergencyClinic> _sorted(List<EmergencyClinic> all) {
    int rank(EmergencyClinic c) => c.communeName == communeName ? 0 : 1;
    return [...all]..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.compareTo(b.name);
    });
  }
}

class _ClinicTile extends ConsumerWidget {
  const new({required this.clinic});

  final EmergencyClinic clinic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = clinic;
    final phone = c.phone.replaceAll(' ', '');
    return ListTile(
      key: Key('clinic-${c.id}'),
      leading: const Icon(Icons.local_hospital_outlined),
      title: Text(c.name),
      subtitle: Text('${c.address} · ${c.communeName}\n${c.phone}'),
      isThreeLine: true,
      trailing: IconButton(
        tooltip: 'Llamar a ${c.name}',
        icon: const Icon(Icons.call_outlined),
        onPressed: () => ref.read(urlOpenerProvider).open('tel:$phone'),
      ),
    );
  }
}
