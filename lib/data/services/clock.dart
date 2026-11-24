import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hora actual y latidos periódicos (refrescos, cuentas regresivas,
/// presencia). Se reemplaza en los tests para controlar el tiempo.
abstract interface class AppClock {
  DateTime now();

  /// Emite cada [period] mientras haya alguien escuchando.
  Stream<void> every(Duration period);
}

class SystemClock implements AppClock {
  const new();

  @override
  DateTime now() => DateTime.now();

  @override
  Stream<void> every(Duration period) => Stream<void>.periodic(period);
}

final clockProvider = Provider<AppClock>((ref) => const SystemClock());
