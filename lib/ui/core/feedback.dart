import 'package:flutter/material.dart';
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/data/repositories/clinical_repository.dart';
import 'package:proyecto_felix/data/repositories/owner_repositories.dart';
import 'package:proyecto_felix/data/repositories/pricing_repository.dart';
import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/repositories/rating_repository.dart';
import 'package:proyecto_felix/data/repositories/subscription_repository.dart';
import 'package:proyecto_felix/data/repositories/vet_repository.dart';
import 'package:proyecto_felix/data/repositories/visit_repository.dart';

/// Mensaje legible de los errores de repositorios.
String friendlyError(Object error) => switch (error) {
  VetFailure(:final message) => message,
  CatalogFailure(:final message) => message,
  OwnerDataFailure(:final message) => message,
  GeocodingFailure(:final message) => message,
  PricingFailure(:final message) => message,
  VisitFailure(:final message) => message,
  ClinicalFailure(:final message) => message,
  PrivacyFailure(:final message) => message,
  RatingFailure(:final message) => message,
  SubscriptionFailure(:final message) => message,
  AccountBlockedException(:final message) => message,
  _ => 'No se pudo completar la acción. Inténtalo de nuevo.',
};

/// Ejecuta una acción, muestra un SnackBar si falla (o el mensaje de éxito) y
/// llama a [onDone] para refrescar. Devuelve true si salió bien.
Future<bool> runWithFeedback(
  BuildContext context,
  Future<void> Function() action, {
  VoidCallback? onDone,
  String? success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    onDone?.call();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } on Object catch (e) {
    onDone?.call();
    messenger.showSnackBar(
      SnackBar(content: Text(friendlyError(e), key: const Key('snack-error'))),
    );
    return false;
  }
}
