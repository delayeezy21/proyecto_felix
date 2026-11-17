import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/pricing.dart';

/// Fundaciones activas para elegir (la RLS oculta las inactivas al dueño).
final FutureProvider<List<Foundation>> foundationsProvider =
    FutureProvider.autoDispose<List<Foundation>>(
      (ref) => ref.watch(foundationRepositoryProvider).foundations(),
    );

/// Fundación elegida en el perfil (null = la por defecto).
final FutureProvider<String?> myFoundationIdProvider =
    FutureProvider.autoDispose<String?>(
      (ref) => ref.watch(foundationRepositoryProvider).myFoundationId(),
    );

/// Pide cotizaciones al servidor. El estado es la última cotización (o null).
class QuoteController extends Notifier<AsyncValue<Quote?>> {
  int _seq = 0;

  @override
  AsyncValue<Quote?> build() => const AsyncData(null);

  Future<void> request(QuoteRequest request) async {
    final seq = ++_seq;
    state = const AsyncLoading();
    try {
      final quote = await ref.read(quoteRepositoryProvider).quote(request);
      if (!ref.mounted || seq != _seq) return;
      state = AsyncData(quote);
    } on Object catch (e, st) {
      if (!ref.mounted || seq != _seq) return;
      state = AsyncError(e, st);
    }
  }

  /// Al cambiar un dato del formulario, la cotización anterior deja de valer.
  void clear() {
    _seq++;
    state = const AsyncData(null);
  }
}

final NotifierProvider<QuoteController, AsyncValue<Quote?>> quoteProvider =
    NotifierProvider.autoDispose(QuoteController.new);

/// Guarda la fundación del perfil.
class FoundationChoiceController extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncData(null);

  Future<bool> choose(String? foundationId) async {
    state = const AsyncLoading();
    try {
      await ref
          .read(foundationRepositoryProvider)
          .setMyFoundation(foundationId);
      if (!ref.mounted) return true;
      ref.invalidate(myFoundationIdProvider);
      state = const AsyncData(null);
      return true;
    } on Object catch (e, st) {
      if (ref.mounted) state = AsyncError(e, st);
      return false;
    }
  }
}

final NotifierProvider<FoundationChoiceController, AsyncValue<void>>
foundationChoiceProvider = NotifierProvider.autoDispose(
  FoundationChoiceController.new,
);
