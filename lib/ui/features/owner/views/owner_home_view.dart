import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:proyecto_felix/core/router/routes.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/features/auth/view_models/auth_controller.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';
import 'package:proyecto_felix/ui/features/owner/views/quote_view.dart';

/// Inicio del dueño: sus mascotas y sus direcciones.
class OwnerHomeView extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = switch (ref.watch(sessionProvider).value) {
      SignedIn(:final account?) => account.displayName,
      _ => '',
    };
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Inicio'),
          actions: [
            IconButton(
              key: const Key('owner-profile'),
              tooltip: 'Mi perfil y fundación',
              icon: const Icon(Icons.volunteer_activism_outlined),
              onPressed: () => context.push(AppRoutes.ownerProfile),
            ),
            IconButton(
              key: const Key('sign-out'),
              tooltip: 'Cerrar sesión',
              icon: const Icon(Icons.logout),
              onPressed: () =>
                  ref.read(authControllerProvider.notifier).signOut(),
            ),
          ],
          bottom: const TabBar(
            tabAlignment: TabAlignment.fill,
            tabs: [
              Tab(icon: Icon(Icons.pets), text: 'Mascotas'),
              Tab(icon: Icon(Icons.home_outlined), text: 'Direcciones'),
              Tab(icon: Icon(Icons.request_quote_outlined), text: 'Cotizar'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _PetsTab(greeting: name),
            const _AddressesTab(),
            const QuotePanel(),
          ],
        ),
      ),
    );
  }
}

Widget _asyncList<T>(
  BuildContext context,
  AsyncValue<List<T>> value, {
  required VoidCallback onRetry,
  required Widget Function(List<T> items) data,
}) => switch (value) {
  AsyncData(:final value) => data(value),
  AsyncError(:final error) => SingleChildScrollView(
    child: EmptyState(
      icon: Icons.cloud_off_outlined,
      title: 'No se pudo cargar.',
      message: friendlyError(error),
      isError: true,
      action: OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh),
        label: const Text('Reintentar'),
      ),
    ),
  ),
  _ => const LoadingView(),
};

class _Header extends StatelessWidget {
  const new({required this.title, required this.action, this.greeting});

  final String title;
  final String? greeting;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((greeting ?? '').isNotEmpty) ...[
            Text('Hola, $greeting', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              action,
            ],
          ),
        ],
      ),
    );
  }
}

class _PetsTab extends ConsumerWidget {
  const new({required this.greeting});

  final String greeting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final add = FilledButton.icon(
      key: const Key('pet-add'),
      onPressed: () => context.push(AppRoutes.ownerPetNew),
      icon: const Icon(Icons.add),
      label: const Text('Agregar mascota'),
    );
    return RefreshIndicator(
      onRefresh: () => ref.refresh(myPetsProvider.future),
      child: _asyncList(
        context,
        ref.watch(myPetsProvider),
        onRetry: () => ref.invalidate(myPetsProvider),
        data: (pets) => MaxWidth(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _Header(title: 'Mis mascotas', greeting: greeting, action: add),
              if (pets.isEmpty)
                const EmptyState(
                  icon: Icons.pets,
                  title: 'Aún no registras mascotas.',
                  message:
                      'Agrega a tu mascota para pedir visitas a domicilio.',
                )
              else
                for (final pet in pets) _PetTile(pet: pet),
            ],
          ),
        ),
      ),
    );
  }
}

class _PetTile extends StatelessWidget {
  const new({required this.pet});

  final Pet pet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      pet.speciesName ?? 'Especie no disponible',
      ?pet.breedName,
      pet.sex.label,
      if (pet.birthDateApprox != null)
        approxAge(pet.birthDateApprox!, DateTime.now()),
      if (!pet.active) 'Desactivada',
    ].join(' · ');
    return ListTile(
      key: Key('pet-${pet.id}'),
      leading: CircleAvatar(
        backgroundColor: pet.active
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        child: Icon(
          Icons.pets,
          color: pet.active
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
      title: Text(pet.name),
      subtitle: Text(details),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(AppRoutes.ownerPet(pet.id)),
    );
  }
}

class _AddressesTab extends ConsumerWidget {
  const new();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final add = FilledButton.icon(
      key: const Key('address-add'),
      onPressed: () => context.push(AppRoutes.ownerAddressNew),
      icon: const Icon(Icons.add_location_alt_outlined),
      label: const Text('Agregar dirección'),
    );
    return RefreshIndicator(
      onRefresh: () => ref.refresh(myAddressesProvider.future),
      child: _asyncList(
        context,
        ref.watch(myAddressesProvider),
        onRetry: () => ref.invalidate(myAddressesProvider),
        data: (addresses) => MaxWidth(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _Header(title: 'Mis direcciones', action: add),
              if (addresses.isEmpty)
                const EmptyState(
                  icon: Icons.home_outlined,
                  title: 'Aún no guardas direcciones.',
                  message:
                      'El veterinario verá la dirección exacta solo cuando '
                      'tome tu visita.',
                )
              else
                for (final a in addresses) _AddressTile(address: a),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddressTile extends StatelessWidget {
  const new({required this.address});

  final Address address;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      address.streetText,
      ?address.details,
      ?address.communeName,
      if (!address.active) 'Desactivada',
    ].join(' · ');
    return ListTile(
      key: Key('address-${address.id}'),
      leading: Icon(
        address.active ? Icons.home_outlined : Icons.location_off_outlined,
      ),
      title: Text(address.label),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push(AppRoutes.ownerAddress(address.id)),
    );
  }
}
