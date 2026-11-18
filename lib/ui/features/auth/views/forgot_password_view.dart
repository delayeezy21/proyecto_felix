import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/dev_mail_hint.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

/// "Olvidé mi contraseña": pide el correo y envía el enlace de recuperación.
/// El mensaje de éxito es el mismo exista o no la cuenta (no se revela).
class ForgotPasswordView extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<ForgotPasswordView> createState() => _ForgotPasswordViewState();
}

class _ForgotPasswordViewState extends ConsumerState<ForgotPasswordView> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _submitted = false;
  String? _sentTo;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitted = true);
    final email = _email.text.trim();
    final ok = await ref
        .read(authControllerProvider.notifier)
        .sendPasswordReset(email: email);
    if (ok && mounted) setState(() => _sentTo = email);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final busy = state.isLoading;
    final sentTo = _sentTo;
    return FormPage(
      title: 'Recuperar contraseña',
      children: [
        if (sentTo != null) ...[
          InfoBanner(
            tone: BannerTone.success,
            icon: Icons.mark_email_read_outlined,
            message:
                'Si $sentTo tiene una cuenta en Felix, te enviamos un enlace '
                'para crear una contraseña nueva. Revisa también la carpeta '
                'de spam.',
            textKey: const Key('forgot-sent'),
            liveRegion: true,
          ),
          const SizedBox(height: 12),
          const DevMailHint(),
          const SizedBox(height: 20),
        ] else ...[
          const Text(
            'Ingresa tu correo y te enviaremos un enlace para crear una '
            'contraseña nueva.',
          ),
          const SizedBox(height: 20),
          Form(
            key: _formKey,
            child: TextFormField(
              key: const Key('forgot-email'),
              controller: _email,
              decoration: const InputDecoration(
                labelText: 'Correo',
                prefixIcon: Icon(Icons.mail_outline),
              ),
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.email],
              validator: Validators.email,
              onFieldSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(height: 20),
          if (state case AsyncError(:final error) when _submitted) ...[
            FormError(errorMessage(error)),
            const SizedBox(height: 12),
          ],
          FilledButton(
            key: const Key('forgot-submit'),
            onPressed: busy ? null : _submit,
            child: busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: 'Enviando',
                    ),
                  )
                : const Text('Enviar enlace'),
          ),
          const SizedBox(height: 16),
        ],
        TextButton(
          key: const Key('forgot-back'),
          onPressed: busy ? null : () => context.go(AppRoutes.login),
          child: const Text('Volver a iniciar sesión'),
        ),
      ],
    );
  }
}
