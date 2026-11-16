import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/dev_mail_hint.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
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
      title: 'Felix',
      children: [
        Text(
          'Veterinarios a domicilio',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                key: const Key('login-email'),
                controller: _email,
                decoration: const InputDecoration(labelText: 'Correo'),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                validator: Validators.email,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('login-password'),
                controller: _password,
                decoration: const InputDecoration(labelText: 'Contraseña'),
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Ingresa tu contraseña' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (state case AsyncError(:final error)) ...[
          FormError(errorMessage(error)),
          const SizedBox(height: 12),
          if (error is AuthFailure && error.isEmailNotConfirmed) ...[
            OutlinedButton(
              key: const Key('login-resend'),
              onPressed: busy ? null : _resend,
              child: const Text('Reenviar correo de confirmación'),
            ),
            const SizedBox(height: 12),
            const DevMailHint(),
            const SizedBox(height: 12),
          ],
        ],
        if (_resentTo != null && !state.hasError) ...[
          Text(
            'Te reenviamos el enlace de confirmación a $_resentTo.',
            key: const Key('login-resent'),
          ),
          const SizedBox(height: 12),
          const DevMailHint(),
          const SizedBox(height: 12),
        ],
        FilledButton(
          key: const Key('login-submit'),
          onPressed: busy ? null : _submit,
          child: const Text('Entrar'),
        ),
        const SizedBox(height: 12),
        if (ref.watch(envProvider).googleAuthEnabled) ...[
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
          const SizedBox(height: 12),
        ],
        TextButton(
          key: const Key('login-go-signup'),
          onPressed: busy ? null : () => context.go(AppRoutes.signUp),
          child: const Text('¿No tienes cuenta? Crear cuenta'),
        ),
      ],
    );
  }
}
