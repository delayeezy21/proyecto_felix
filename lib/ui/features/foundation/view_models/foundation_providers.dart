import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';

/// Fundación del miembro actual (null si su membresía no está activa).
final FutureProvider<Foundation?> memberFoundationProvider =
    FutureProvider.autoDispose<Foundation?>(
      (ref) => ref.watch(foundationRepositoryProvider).memberFoundation(),
    );

/// Totales agregados por mes (12 meses). Nunca filas de pagos ni dueños.
final FutureProvider<List<FoundationMonth>> foundationSummaryProvider =
    FutureProvider.autoDispose<List<FoundationMonth>>(
      (ref) => ref.watch(foundationRepositoryProvider).summary(),
    );

/// Totales del período mostrado.
({int commission, int donation, int total}) summaryTotals(
  List<FoundationMonth> months,
) => (
  commission: months.fold(0, (a, m) => a + m.commissionTotal),
  donation: months.fold(0, (a, m) => a + m.donationTotal),
  total: months.fold(0, (a, m) => a + m.total),
);
