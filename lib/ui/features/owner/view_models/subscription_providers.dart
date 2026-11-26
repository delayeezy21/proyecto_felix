import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/subscription_repository.dart';
import 'package:proyecto_felix/domain/models/subscription.dart';

/// Planes activos para contratar.
final FutureProvider<List<SubscriptionPlan>> subscriptionPlansProvider =
    FutureProvider.autoDispose<List<SubscriptionPlan>>(
      (ref) => ref.watch(subscriptionRepositoryProvider).plans(),
    );

/// Mi suscripción (null si no tengo una abierta o vigente).
final FutureProvider<Subscription?> mySubscriptionProvider =
    FutureProvider.autoDispose<Subscription?>(
      (ref) => ref.watch(subscriptionRepositoryProvider).mine(),
    );

/// Contrata, cambia mascotas o cancela. El estado indica si hay una acción en
/// curso o el último error; al terminar refresca [mySubscriptionProvider].
class SubscriptionController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  Future<bool> _run(
    Future<Subscription> Function(SubscriptionRepository r) action,
  ) async {
    if (state.isLoading) return false;
    state = const AsyncLoading();
    try {
      await action(ref.read(subscriptionRepositoryProvider));
      if (!ref.mounted) return true;
      ref.invalidate(mySubscriptionProvider);
      state = const AsyncData(null);
      return true;
    } on Object catch (e, st) {
      if (ref.mounted) state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> subscribe(int planId, List<String> petIds) =>
      _run((r) => r.subscribe(planId, petIds));

  Future<bool> setPets(List<String> petIds) => _run((r) => r.setPets(petIds));

  Future<bool> cancel() => _run((r) => r.cancel());
}

final NotifierProvider<SubscriptionController, AsyncValue<void>>
subscriptionControllerProvider = NotifierProvider.autoDispose(
  SubscriptionController.new,
);
