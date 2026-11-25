import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/features/privacy/view_models/privacy_providers.dart';

/// Texto de la política (el mismo que se lee al registrarse).
const privacyPolicyAsset = 'assets/legal/privacidad.txt';

final FutureProvider<String> privacyPolicyTextProvider =
    FutureProvider.autoDispose(
      (ref) => rootBundle.loadString(privacyPolicyAsset),
    );

/// Política de privacidad vigente con su versión (HU8.4). Al abrirla se
/// registra que el usuario la vio (`record_privacy_notice_view`): es deber de
/// información, no un consentimiento.
class PrivacyPolicyView extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<PrivacyPolicyView> createState() => _PrivacyPolicyViewState();
}

class _PrivacyPolicyViewState extends ConsumerState<PrivacyPolicyView> {
  @override
  void initState() {
    super.initState();
    unawaited(_markSeen());
  }

  Future<void> _markSeen() async {
    try {
      await ref.read(privacyStatusProvider.notifier).markNoticeSeen();
    } on Object {
      // Si falla, el aviso volverá a aparecer en la próxima sesión.
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = ref.watch(privacyStatusProvider).value?.privacyVersion;
    final text = ref.watch(privacyPolicyTextProvider);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Política de privacidad')),
      body: MaxWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (version != null)
              Text(
                'Versión vigente: $version',
                key: const Key('policy-version'),
                style: theme.textTheme.titleSmall,
              ),
            const SizedBox(height: 12),
            switch (text) {
              AsyncData(:final value) => SelectableText(value),
              AsyncError() => const Text(
                'No se pudo abrir la política. Inténtalo de nuevo.',
              ),
              _ => const LoadingView(),
            },
          ],
        ),
      ),
    );
  }
}
