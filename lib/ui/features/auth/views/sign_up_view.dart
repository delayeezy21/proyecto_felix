import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/dev_mail_hint.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

class SignUpView extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<SignUpView> createState() => _SignUpViewState();
}

class _SignUpViewState extends ConsumerState<SignUpView> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _confirmationSent = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final result = await ref
        .read(authControllerProvider.notifier)
        .signUp(email: _email.text, password: _password.text);
    if (!mounted) return;
    if (result == SignUpResult.confirmationRequired) {
      setState(() => _confirmationSent = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_confirmationSent) {
      return FormPage(
        title: 'Revisa tu correo',
        children: [
          Text(
            'Te enviamos un enlace a ${_email.text.trim()} para confirmar tu '
            'cuenta. Después de confirmarla, inicia sesión.',
            key: const Key('signup-confirmation'),
          ),
          const SizedBox(height: 16),
          const DevMailHint(),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => context.go(AppRoutes.login),
            child: const Text('Ir a iniciar sesión'),
          ),
        ],
      );
    }

    final state = ref.watch(authControllerProvider);
    final busy = state.isLoading;
    return FormPage(
      title: 'Crear cuenta',
      children: [
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                key: const Key('signup-email'),
                controller: _email,
                decoration: const InputDecoration(labelText: 'Correo'),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                validator: Validators.email,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('signup-password'),
                controller: _password,
                decoration: const InputDecoration(
                  labelText: 'Contraseña',
                  helperText:
                      'Mínimo 8 caracteres, con mayúsculas, '
                      'minúsculas y números',
                ),
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                validator: Validators.password,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('signup-confirm'),
                controller: _confirm,
                decoration: const InputDecoration(
                  labelText: 'Repite la contraseña',
                ),
                obscureText: true,
                validator: (v) =>
                    v != _password.text ? 'Las contraseñas no coinciden' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (state case AsyncError(:final error)) ...[
          FormError(errorMessage(error)),
          const SizedBox(height: 16),
        ],
        FilledButton(
          key: const Key('signup-submit'),
          onPressed: busy ? null : _submit,
          child: const Text('Crear cuenta'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: busy ? null : () => context.go(AppRoutes.login),
          child: const Text('Ya tengo cuenta'),
        ),
      ],
    );
  }
}
