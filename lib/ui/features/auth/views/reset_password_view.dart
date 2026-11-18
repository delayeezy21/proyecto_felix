import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/core/password_field.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';

/// Contraseña nueva al volver del enlace de recuperación. El router trae al
/// usuario aquí mientras dure la recuperación (ver `AppRoutes.redirect`).
class ResetPasswordView extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<ResetPasswordView> createState() => _ResetPasswordViewState();
}

class _ResetPasswordViewState extends ConsumerState<ResetPasswordView> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitted = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitted = true);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref
        .read(authControllerProvider.notifier)
        .updatePassword(_password.text);
    if (ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Tu contraseña se actualizó.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final busy = state.isLoading;
    return FormPage(
      title: 'Nueva contraseña',
      children: [
        const Text('Crea una contraseña nueva para tu cuenta.'),
        const SizedBox(height: 20),
        AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                PasswordField(
                  fieldKey: const Key('reset-password'),
                  controller: _password,
                  label: 'Contraseña nueva',
                  helperText:
                      'Mínimo 8 caracteres, con mayúsculas, '
                      'minúsculas y números',
                  autofillHints: const [AutofillHints.newPassword],
                  textInputAction: TextInputAction.next,
                  validator: Validators.password,
                ),
                const SizedBox(height: 16),
                PasswordField(
                  fieldKey: const Key('reset-confirm'),
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
        if (state case AsyncError(:final error) when _submitted) ...[
          FormError(errorMessage(error)),
          const SizedBox(height: 12),
        ],
        FilledButton(
          key: const Key('reset-submit'),
          onPressed: busy ? null : _submit,
          child: busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Guardando',
                  ),
                )
              : const Text('Guardar contraseña'),
        ),
        const SizedBox(height: 16),
        TextButton(
          key: const Key('reset-cancel'),
          onPressed: busy
              ? null
              : () => ref.read(authControllerProvider.notifier).signOut(),
          child: const Text('Cancelar y cerrar sesión'),
        ),
      ],
    );
  }
}
