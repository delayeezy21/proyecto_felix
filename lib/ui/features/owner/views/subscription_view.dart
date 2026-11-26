import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/subscription.dart';
import 'package:proyecto_felix/domain/models/visit.dart' show formatDay;
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/subscription_providers.dart';

/// "Mi plan" (fase 10): contratar, elegir mascotas y cancelar una
/// suscripción simulada. Los beneficios los aplica el servidor al cotizar.
class SubscriptionView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(subscriptionPlansProvider);
    final mine = ref.watch(mySubscriptionProvider);
    final pets = ref.watch(myPetsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mi plan')),
      body: switch ((plans, mine, pets)) {
        (
          AsyncData(value: final plans),
          AsyncData(value: final sub),
          AsyncData(value: final pets),
        ) =>
          MaxWidth(
            child: RefreshIndicator(
              onRefresh: () => ref.refresh(mySubscriptionProvider.future),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (sub != null) ...[
                    _CurrentPlan(sub: sub, pets: _active(pets)),
                    const SizedBox(height: 24),
                  ],
                  if (sub == null || sub.status != SubscriptionStatus.active)
                    ..._catalog(context, plans, _active(pets), sub),
                  const SizedBox(height: 16),
                  Text(
                    'Pago simulado: no se cobra dinero real. El descuento lo '
                    'cubre Felix: tu veterinario/a recibe su tarifa completa.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        (AsyncError(:final error), _, _) ||
        (_, AsyncError(:final error), _) ||
        (_, _, AsyncError(:final error)) => SingleChildScrollView(
          child: EmptyState(
            icon: Icons.cloud_off_outlined,
            title: 'No se pudo cargar tu plan.',
            message: friendlyError(error),
            isError: true,
            action: OutlinedButton.icon(
              onPressed: () => ref
                ..invalidate(subscriptionPlansProvider)
                ..invalidate(mySubscriptionProvider)
                ..invalidate(myPetsProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ),
        ),
        _ => const LoadingView(),
      },
    );
  }

  static List<Pet> _active(List<Pet> pets) =>
      pets.where((p) => p.active).toList();

  List<Widget> _catalog(
    BuildContext context,
    List<SubscriptionPlan> plans,
    List<Pet> pets,
    Subscription? sub,
  ) => [
    Text(
      sub == null ? 'Elige un plan' : 'Contratar otro plan',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    const SizedBox(height: 8),
    if (sub != null)
      const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: InfoBanner(
          message:
              'Si contratas otro plan ahora, el actual termina hoy y el nuevo '
              'empieza de inmediato.',
        ),
      ),
    if (pets.isEmpty)
      const InfoBanner(
        key: Key('plan-no-pets'),
        tone: BannerTone.warning,
        message: 'Agrega una mascota para poder contratar un plan.',
      )
    else if (plans.isEmpty)
      const InfoBanner(message: 'No hay planes disponibles por ahora.'),
    for (final p in plans)
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _PlanCard(plan: p, pets: pets),
      ),
  ];
}

class _CurrentPlan extends ConsumerWidget {
  const new({required this.sub, required this.pets});

  final Subscription sub;
  final List<Pet> pets;

  Future<void> _editPets(BuildContext context, WidgetRef ref) async {
    final chosen = await pickPlanPets(
      context,
      pets: pets,
      max: sub.plan.maxPets,
      initial: {for (final p in sub.pets) p.petId},
    );
    if (chosen == null || !context.mounted) return;
    final ok = await ref
        .read(subscriptionControllerProvider.notifier)
        .setPets(chosen);
    if (context.mounted) {
      _report(context, ref, ok, 'Mascotas del plan guardadas');
    }
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Cancelar tu plan?'),
        content: Text(
          'No se renovará. Mantienes los beneficios hasta el '
          '${formatDay(sub.lastBenefitDay)}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            key: const Key('plan-cancel-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar plan'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await ref.read(subscriptionControllerProvider.notifier).cancel();
    if (context.mounted) _report(context, ref, ok, 'Plan cancelado');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = ref.watch(subscriptionControllerProvider).isLoading;
    final active = sub.status == SubscriptionStatus.active;
    final plan = sub.plan;
    return Card(
      key: const Key('plan-current'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Plan ${plan.name}',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Chip(
                  key: const Key('plan-status'),
                  label: Text(sub.status.label),
                ),
              ],
            ),
            Text('${formatClp(plan.priceMonthly)} al mes'),
            for (final b in plan.benefits) _Benefit(b),
            const Divider(height: 24),
            Text(
              active
                  ? 'Se renueva el ${formatDay(sub.currentPeriodEnd)}.'
                  : 'No se renovará. Beneficios hasta el '
                        '${formatDay(sub.lastBenefitDay)}.',
              key: const Key('plan-period'),
            ),
            if (plan.preventivePerYear > 0)
              Text(
                'Preventivas incluidas: te quedan '
                '${sub.preventiveRemaining} de ${plan.preventivePerYear} '
                '(últimos 12 meses).',
                key: const Key('plan-preventive'),
              ),
            const SizedBox(height: 4),
            Text('Mascotas del plan', style: theme.textTheme.titleSmall),
            if (sub.pets.isEmpty)
              const Text('Ninguna mascota asociada.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in sub.pets)
                    Chip(
                      avatar: const Icon(Icons.pets, size: 18),
                      label: Text(p.active ? p.name : '${p.name} (inactiva)'),
                    ),
                ],
              ),
            if (active) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('plan-edit-pets'),
                onPressed: busy || pets.isEmpty
                    ? null
                    : () => _editPets(context, ref),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Cambiar mascotas'),
              ),
              TextButton.icon(
                key: const Key('plan-cancel'),
                onPressed: busy ? null : () => _cancel(context, ref),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancelar plan'),
              ),
              Text(
                'Para cambiar de plan, cancela el actual y contrata el nuevo.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlanCard extends ConsumerWidget {
  const new({required this.plan, required this.pets});

  final SubscriptionPlan plan;
  final List<Pet> pets;

  Future<void> _subscribe(BuildContext context, WidgetRef ref) async {
    final chosen = await pickPlanPets(
      context,
      pets: pets,
      max: plan.maxPets,
      initial: {if (pets.length == 1) pets.first.id},
      confirmLabel: 'Contratar por ${formatClp(plan.priceMonthly)}/mes',
    );
    if (chosen == null || !context.mounted) return;
    final ok = await ref
        .read(subscriptionControllerProvider.notifier)
        .subscribe(plan.id, chosen);
    if (context.mounted) {
      _report(context, ref, ok, 'Plan ${plan.name} contratado');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final busy = ref.watch(subscriptionControllerProvider).isLoading;
    return Card(
      key: Key('plan-${plan.slug}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(plan.name, style: theme.textTheme.titleLarge),
                ),
                Text(
                  formatClp(plan.priceMonthly),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
                const Text(' /mes'),
              ],
            ),
            for (final b in plan.benefits) _Benefit(b),
            const SizedBox(height: 6),
            FilledButton(
              key: Key('plan-subscribe-${plan.slug}'),
              onPressed: busy || pets.isEmpty
                  ? null
                  : () => _subscribe(context, ref),
              child: const Text('Contratar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Benefit extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: [
      Icon(
        Icons.check_circle_outline,
        size: 20,
        color: Theme.of(context).colorScheme.primary,
      ),
      Expanded(child: Text(text)),
    ],
  );
}

void _report(BuildContext context, WidgetRef ref, bool ok, String done) {
  final error = ref.read(subscriptionControllerProvider).error;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(ok ? done : friendlyError(error ?? Exception()))),
  );
}

/// Elige hasta [max] mascotas para el plan. Devuelve null si se cierra.
Future<List<String>?> pickPlanPets(
  BuildContext context, {
  required List<Pet> pets,
  required int max,
  Set<String> initial = const {},
  String confirmLabel = 'Guardar',
}) => showDialog<List<String>>(
  context: context,
  builder: (context) => _PetPickerDialog(
    pets: pets,
    max: max,
    initial: initial,
    confirmLabel: confirmLabel,
  ),
);

class _PetPickerDialog extends StatefulWidget {
  const new({
    required this.pets,
    required this.max,
    required this.initial,
    required this.confirmLabel,
  });

  final List<Pet> pets;
  final int max;
  final Set<String> initial;
  final String confirmLabel;

  @override
  State<_PetPickerDialog> createState() => _PetPickerDialogState();
}

class _PetPickerDialogState extends State<_PetPickerDialog> {
  late final Set<String> _selected = {
    for (final p in widget.pets)
      if (widget.initial.contains(p.id)) p.id,
  };

  @override
  Widget build(BuildContext context) {
    final full = _selected.length >= widget.max;
    return AlertDialog(
      title: Text(
        widget.max == 1
            ? 'Elige la mascota'
            : 'Elige hasta ${widget.max} mascotas',
      ),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in widget.pets)
              CheckboxListTile(
                key: Key('plan-pet-${p.id}'),
                value: _selected.contains(p.id),
                title: Text(p.name),
                subtitle: p.speciesName == null ? null : Text(p.speciesName!),
                onChanged: !_selected.contains(p.id) && full && widget.max > 1
                    ? null
                    : (v) => setState(() {
                        if (v ?? false) {
                          // Con una sola mascota permitida, elegir reemplaza.
                          if (widget.max == 1) _selected.clear();
                          _selected.add(p.id);
                        } else {
                          _selected.remove(p.id);
                        }
                      }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Volver'),
        ),
        FilledButton(
          key: const Key('plan-pets-confirm'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, [
                  for (final p in widget.pets)
                    if (_selected.contains(p.id)) p.id,
                ]),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
