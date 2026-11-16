import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/core/config/env.dart';

/// Configuración de la app. Se sobrescribe en `main` y en los tests.
final envProvider = Provider<Env>(
  (ref) => throw UnimplementedError('envProvider debe sobrescribirse'),
);
