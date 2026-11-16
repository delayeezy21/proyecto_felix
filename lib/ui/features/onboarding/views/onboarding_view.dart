import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/validators.dart';
import 'package:proyecto_felix/ui/core/form_error.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';
import 'package:proyecto_felix/ui/features/onboarding/view_models/onboarding_controller.dart';

/// Completa el registro: rol, datos mínimos, términos y aviso de privacidad.
class OnboardingView extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends ConsumerState<OnboardingView> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  AppRole _role = AppRole.owner;
  bool _acceptTerms = false;
  bool _marketing = false;
  bool _showTermsError = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit(LegalVersions legal) async {
    final formOk = _formKey.currentState?.validate() ?? false;
    setState(() => _showTermsError = !_acceptTerms);
    if (!formOk || !_acceptTerms) return;
    await ref
        .read(onboardingControllerProvider.notifier)
        .submit(
          role: _role,
          displayName: _name.text,
          phone: _role == AppRole.owner ? _phone.text : null,
          legal: legal,
          marketingConsent: _marketing,
        );
  }

  Future<void> _showDocument(String title, String asset) async {
    final text = await rootBundle.loadString(asset);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final legal = ref.watch(legalVersionsProvider);
    final submit = ref.watch(onboardingControllerProvider);
    final busy = submit.isLoading;

    return FormPage(
      title: 'Completa tu registro',
      children: [
        switch (legal) {
          AsyncData(:final value) => _buildForm(context, value, submit, busy),
          AsyncError() => Column(
            children: [
              const FormError('No se pudieron cargar los términos vigentes.'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(legalVersionsProvider),
                child: const Text('Reintentar'),
              ),
            ],
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
        const SizedBox(height: 12),
        TextButton(
          onPressed: busy
              ? null
              : () => ref.read(authControllerProvider.notifier).signOut(),
          child: const Text('Cerrar sesión'),
        ),
      ],
    );
  }

  Widget _buildForm(
    BuildContext context,
    LegalVersions legal,
    AsyncValue<void> submit,
    bool busy,
  ) {
    final textTheme = Theme.of(context).textTheme;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('¿Cómo usarás Felix?', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<AppRole>(
            key: const Key('onboarding-role'),
            segments: const [
              ButtonSegment(
                value: AppRole.owner,
                label: Text('Tengo mascotas'),
                icon: Icon(Icons.pets),
              ),
              ButtonSegment(
                value: AppRole.vet,
                label: Text('Soy veterinario'),
                icon: Icon(Icons.medical_services),
              ),
            ],
            selected: {_role},
            onSelectionChanged: busy
                ? null
                : (s) => setState(() => _role = s.first),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('onboarding-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: _role == AppRole.vet
                  ? 'Nombre profesional'
                  : 'Nombre para mostrar',
            ),
            textCapitalization: TextCapitalization.words,
            validator: Validators.displayName,
          ),
          if (_role == AppRole.owner) ...[
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('onboarding-phone'),
              controller: _phone,
              decoration: const InputDecoration(
                labelText: 'Teléfono',
                helperText:
                    'Solo lo verá el veterinario asignado durante la visita',
              ),
              keyboardType: TextInputType.phone,
              validator: (v) => Validators.phone(v, required: true),
            ),
          ],
          if (_role == AppRole.vet) ...[
            const SizedBox(height: 12),
            Text(
              'Tu cuenta quedará pendiente hasta que un administrador revise '
              'tu título y carnet (los subirás en el siguiente paso).',
              style: textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 20),
          // Aviso de privacidad: deber de información (no es consentimiento).
          Text(
            'Usamos tus datos solo para prestar el servicio. Puedes '
            'descargarlos o borrar tu cuenta cuando quieras.',
            style: textTheme.bodySmall,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _showDocument(
                'Política de privacidad (v${legal.privacy})',
                'assets/legal/privacidad.txt',
              ),
              child: const Text('Leer la política de privacidad'),
            ),
          ),
          CheckboxListTile(
            key: const Key('onboarding-terms'),
            value: _acceptTerms,
            onChanged: busy
                ? null
                : (v) => setState(() {
                    _acceptTerms = v ?? false;
                    if (_acceptTerms) _showTermsError = false;
                  }),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: Text('Acepto los términos y condiciones (v${legal.terms})'),
            subtitle: _showTermsError
                ? Text(
                    'Debes aceptar los términos para continuar',
                    key: const Key('onboarding-terms-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                : null,
            secondary: IconButton(
              tooltip: 'Leer los términos',
              icon: const Icon(Icons.description_outlined),
              onPressed: () => _showDocument(
                'Términos y condiciones (v${legal.terms})',
                'assets/legal/terminos.txt',
              ),
            ),
          ),
          CheckboxListTile(
            key: const Key('onboarding-marketing'),
            value: _marketing,
            onChanged: busy
                ? null
                : (v) => setState(() => _marketing = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('Quiero recibir novedades (opcional)'),
          ),
          const SizedBox(height: 16),
          if (submit case AsyncError(:final error)) ...[
            FormError(onboardingErrorMessage(error)),
            const SizedBox(height: 16),
          ],
          FilledButton(
            key: const Key('onboarding-submit'),
            onPressed: busy ? null : () => _submit(legal),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
  }
}
