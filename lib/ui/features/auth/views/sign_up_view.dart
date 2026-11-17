import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/brand.dart';
import 'package:proyecto_felix/ui/core/dev_mail_hint.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/password_field.dart';
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
    final theme = Theme.of(context);
    if (_confirmationSent) {
      return FormPage(
        title: 'Revisa tu correo',
        children: [
          Center(
            child: ExcludeSemantics(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.mark_email_unread_outlined,
                  size: 36,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Te enviamos un enlace a ${_email.text.trim()} para confirmar tu '
            'cuenta. Después de confirmarla, inicia sesión.',
            key: const Key('signup-confirmation'),
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Si no lo ves en unos minutos, revisa la carpeta de spam.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
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
        const BrandHeader(
          showName: false,
          tagline: 'Crea tu cuenta para empezar',
        ),
        const SizedBox(height: 28),
        AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  key: const Key('signup-email'),
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
                  fieldKey: const Key('signup-password'),
                  controller: _password,
                  label: 'Contraseña',
                  helperText:
                      'Mínimo 8 caracteres, con mayúsculas, '
                      'minúsculas y números',
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.next,
                  validator: Validators.password,
                ),
                const SizedBox(height: 16),
                PasswordField(
                  fieldKey: const Key('signup-confirm'),
                  controller: _confirm,
                  label: 'Repite la contraseña',
                  textInputAction: TextInputAction.done,
                  validator: (v) => v != _password.text
                      ? 'Las contraseñas no coinciden'
                      : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (state case AsyncError(:final error)) ...[
          FormError(errorMessage(error)),
          const SizedBox(height: 16),
        ],
        FilledButton(
          key: const Key('signup-submit'),
          onPressed: busy ? null : _submit,
          child: busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Creando cuenta',
                  ),
                )
              : const Text('Crear cuenta'),
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
