import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

/// Visitas del usuario actual (el servidor decide qué ve el dueño y el vet).
final FutureProvider<List<Visit>> myVisitsProvider =
    FutureProvider.autoDispose<List<Visit>>(
      (ref) => ref.watch(visitRepositoryProvider).myVisits(),
    );

/// Punto de partida del vet actual (null = aún no lo define).
final FutureProvider<VetBase?> vetBaseProvider =
    FutureProvider.autoDispose<VetBase?>(
      (ref) => ref.watch(vetAgendaRepositoryProvider).myBase(),
    );

/// Días libres del vet actual.
final FutureProvider<List<TimeOff>> timeOffProvider =
    FutureProvider.autoDispose<List<TimeOff>>(
      (ref) => ref.watch(vetAgendaRepositoryProvider).myTimeOff(),
    );

/// Resumen agregado de visitas para el admin.
final FutureProvider<List<VisitStatusCount>> adminVisitSummaryProvider =
    FutureProvider.autoDispose<List<VisitStatusCount>>(
      (ref) => ref.watch(visitRepositoryProvider).adminSummary(),
    );

/// Pide una transición, refresca la lista y devuelve el cargo aplicado.
Future<int> requestTransition(
  WidgetRef ref,
  String visitId,
  VisitStatus to, {
  String? reason,
}) async {
  try {
    return await ref
        .read(visitRepositoryProvider)
        .transition(visitId, to, reason: reason);
  } finally {
    ref.invalidate(myVisitsProvider);
  }
}
