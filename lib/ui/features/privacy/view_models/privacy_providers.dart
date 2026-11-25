import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/privacy_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/data/services/clock.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/domain/models/privacy.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

/// Política vigente y consentimientos opcionales (`my_privacy_status`).
class PrivacyStatusController extends AsyncNotifier<PrivacyStatus> {
  PrivacyRepository get _repo => ref.read(privacyRepositoryProvider);

  @override
  Future<PrivacyStatus> build() =>
      ref.watch(privacyRepositoryProvider).status();

  /// Otorga o retira una finalidad. Lanza el error para que la vista lo
  /// muestre; el estado anterior se mantiene.
  Future<void> setConsent(String purpose, {required bool granted}) async {
    final next = await _repo.setConsent(purpose, granted: granted);
    if (ref.mounted) state = AsyncData(next);
  }

  /// Registra que el usuario vio la política vigente (HU8.4).
  Future<void> markNoticeSeen() async {
    final next = await _repo.recordNoticeView();
    if (ref.mounted) state = AsyncData(next);
  }
}

final AsyncNotifierProvider<PrivacyStatusController, PrivacyStatus>
privacyStatusProvider = AsyncNotifierProvider.autoDispose(
  PrivacyStatusController.new,
);

/// "Más tarde" en el aviso de política nueva: se oculta hasta la próxima
/// sesión (el aviso no bloquea el uso normal).
class NoticeDismissedController extends Notifier<bool> {
  @override
  bool build() {
    // Otra sesión (u otro usuario) vuelve a ver el aviso.
    ref.watch(sessionProvider.select((s) => s.value));
    return false;
  }

  void dismiss() => state = true;
}

final NotifierProvider<NoticeDismissedController, bool>
noticeDismissedProvider = NotifierProvider(NoticeDismissedController.new);

/// Exporta mis datos (`export_my_data`) y los guarda como archivo JSON.
class DataExportController extends AsyncNotifier<void> {
  @override
  void build() {}

  /// Devuelve el nombre del archivo, o null si el usuario canceló el
  /// diálogo. Los errores quedan en `state` y se relanzan.
  Future<String?> export() async {
    state = const AsyncLoading();
    try {
      final data = await ref.read(privacyRepositoryProvider).exportMyData();
      final name = exportFileName(ref.read(clockProvider).now());
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
      );
      final saved = await ref
          .read(fileSaverProvider)
          .save(fileName: name, bytes: bytes, mimeType: 'application/json');
      if (ref.mounted) state = const AsyncData(null);
      return saved ? name : null;
    } catch (e, st) {
      if (ref.mounted) state = AsyncError(e, st);
      rethrow;
    }
  }
}

final AsyncNotifierProvider<DataExportController, void> dataExportProvider =
    AsyncNotifierProvider.autoDispose(DataExportController.new);

/// Solicitud de eliminación de cuenta (HU8.2).
class DeletionController extends AsyncNotifier<DeletionRequest?> {
  PrivacyRepository get _repo => ref.read(privacyRepositoryProvider);

  @override
  Future<DeletionRequest?> build() =>
      ref.watch(privacyRepositoryProvider).myDeletionRequest();

  /// Pide el borrado (la cuenta queda bloqueada) y cierra la sesión local:
  /// el servidor ya revocó las sesiones.
  Future<DeletionRequest> request() async {
    final r = await _repo.requestDeletion();
    if (ref.mounted) state = AsyncData(r);
    await ref.read(authControllerProvider.notifier).signOut();
    return r;
  }

  /// Cancela el borrado y vuelve al inicio normal.
  Future<void> cancel() async {
    final r = await _repo.cancelDeletion();
    if (!ref.mounted) return;
    state = AsyncData(r);
    resume();
  }

  /// La cuenta ya no está bloqueada: limpia el aviso y recarga la sesión.
  void resume() {
    ref.read(accountBlockedSignalProvider).clear();
    ref.invalidate(sessionProvider);
  }
}

final AsyncNotifierProvider<DeletionController, DeletionRequest?>
deletionRequestProvider = AsyncNotifierProvider.autoDispose(
  DeletionController.new,
);

/// Vet: entradas retenidas de las que es autor (vacío si no es vet).
final FutureProvider<List<RetainedEntry>> retainedEntriesProvider =
    FutureProvider.autoDispose(
      (ref) => ref.watch(privacyRepositoryProvider).retainedEntries(),
    );

/// Vet: consulta una entrada retenida con motivo (queda registrada).
Future<RetainedEntryDetail> requestRetainedEntry(
  WidgetRef ref,
  String entryId,
  String reason,
) => ref
    .read(privacyRepositoryProvider)
    .requestRetainedEntry(entryId, reason: reason);
