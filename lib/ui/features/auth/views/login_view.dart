import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/brand.dart';
import 'package:proyecto_felix/ui/core/dev_mail_hint.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/core/password_field.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

class LoginView extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<LoginView> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _resentTo;

  Future<void> _resend() async {
    final email = _email.text.trim();
    final ok = await ref
        .read(authControllerProvider.notifier)
        .resendConfirmation(email: email);
    if (ok && mounted) setState(() => _resentTo = email);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _resentTo = null);
    await ref
        .read(authControllerProvider.notifier)
        .signIn(email: _email.text, password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final busy = state.isLoading;
    return FormPage(
      title: 'Iniciar sesión',
      children: [
        const BrandHeader(),
        const SizedBox(height: 32),
        AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  key: const Key('login-email'),
                  controller: _email,
                  decoration: const InputDecoration(
                    labelText: 'Correo',
                    prefixIcon: Icon(Icons.mail_outline),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  validator: Validators.email,
                ),
                const SizedBox(height: 16),
                PasswordField(
                  fieldKey: const Key('login-password'),
                  controller: _password,
                  label: 'Contraseña',
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Ingresa tu contraseña' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (state case AsyncError(:final error)) ...[
          FormError(errorMessage(error)),
          const SizedBox(height: 12),
          if (error is AuthFailure && error.isEmailNotConfirmed) ...[
            OutlinedButton.icon(
              key: const Key('login-resend'),
              onPressed: busy ? null : _resend,
              icon: const Icon(Icons.forward_to_inbox_outlined),
              label: const Text('Reenviar correo de confirmación'),
            ),
            const SizedBox(height: 12),
            const DevMailHint(),
            const SizedBox(height: 12),
          ],
        ],
        if (_resentTo != null && !state.hasError) ...[
          InfoBanner(
            tone: BannerTone.success,
            icon: Icons.mark_email_read_outlined,
            message: 'Te reenviamos el enlace de confirmación a $_resentTo.',
            textKey: const Key('login-resent'),
            liveRegion: true,
          ),
          const SizedBox(height: 12),
          const DevMailHint(),
          const SizedBox(height: 12),
        ],
        FilledButton(
          key: const Key('login-submit'),
          onPressed: busy ? null : _submit,
          child: busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Entrando',
                  ),
                )
              : const Text('Entrar'),
        ),
        if (ref.watch(envProvider).googleAuthEnabled) ...[
          const SizedBox(height: 16),
          const _OrDivider(),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('login-google'),
            onPressed: busy
                ? null
                : () => ref
                      .read(authControllerProvider.notifier)
                      .signInWithGoogle(),
            icon: const Icon(Icons.login),
            label: const Text('Continuar con Google'),
          ),
        ],
        const SizedBox(height: 16),
        TextButton(
          key: const Key('login-go-signup'),
          onPressed: busy ? null : () => context.go(AppRoutes.signUp),
          child: const Text('¿No tienes cuenta? Crear cuenta'),
        ),
      ],
    );
  }
}

/// Separador "o" entre el acceso con correo y el de Google.
class _OrDivider extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('o', style: style),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}
