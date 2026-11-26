import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show FutureProviderFamily;
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/domain/models/admin_client.dart';
import 'package:proyecto_felix/domain/models/catalog.dart' show formatClp;
import 'package:proyecto_felix/domain/models/visit.dart'
    show VisitStatus, formatDay;
import 'package:proyecto_felix/ui/core/empty_state.dart';
import 'package:proyecto_felix/ui/core/feedback.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';

/// Clientes que coinciden con la búsqueda ('' = los más recientes).
final FutureProviderFamily<List<AdminClient>, String> adminClientsProvider =
    FutureProvider.autoDispose.family<List<AdminClient>, String>(
      (ref, search) =>
          ref.watch(adminClientRepositoryProvider).list(search: search),
    );

final FutureProviderFamily<AdminClientDetail, String>
adminClientDetailProvider = FutureProvider.autoDispose
    .family<AdminClientDetail, String>(
      (ref, id) => ref.watch(adminClientRepositoryProvider).detail(id),
    );

/// Sección "Clientes" del admin: buscar dueños y ver su contacto y totales,
/// para dar soporte. Sin mascotas, direcciones ni plan (minimización).
class AdminClientsTab extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<AdminClientsTab> createState() => _AdminClientsTabState();
}

class _AdminClientsTabState extends ConsumerState<AdminClientsTab> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _submit() => setState(() => _query = _search.text.trim());

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(adminClientsProvider(_query));
    return MaxWidth(
      maxWidth: 1000,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              key: const Key('admin-clients-search'),
              controller: _search,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Buscar por nombre, correo, teléfono o comuna',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  key: const Key('admin-clients-search-go'),
                  tooltip: 'Buscar',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _submit,
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: InfoBanner(
              icon: Icons.shield_outlined,
              message:
                  'Solo contacto y totales para dar soporte. Las mascotas, '
                  'direcciones, fichas y planes no se muestran.',
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: switch (clients) {
              AsyncData(value: final list) when list.isEmpty =>
                SingleChildScrollView(
                  child: EmptyState(
                    icon: Icons.person_search_outlined,
                    title: _query.isEmpty
                        ? 'Aún no hay clientes.'
                        : 'Sin resultados para "$_query".',
                  ),
                ),
              AsyncData(value: final list) => RefreshIndicator(
                onRefresh: () =>
                    ref.refresh(adminClientsProvider(_query).future),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: list.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => i == 0
                      ? Text(
                          '${list.length} '
                          '${list.length == 1 ? 'cliente' : 'clientes'}',
                          key: const Key('admin-clients-count'),
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : _ClientTile(client: list[i - 1]),
                ),
              ),
              AsyncError(:final error) => SingleChildScrollView(
                child: EmptyState(
                  icon: Icons.cloud_off_outlined,
                  title: 'No se pudieron cargar los clientes.',
                  message: friendlyError(error),
                  isError: true,
                  action: OutlinedButton.icon(
                    onPressed: () =>
                        ref.invalidate(adminClientsProvider(_query)),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ),
              ),
              _ => const LoadingView(),
            },
          ),
        ],
      ),
    );
  }
}

class _ClientTile extends StatelessWidget {
  const new({required this.client});

  final AdminClient client;

  @override
  Widget build(BuildContext context) {
    final c = client;
    final details = [
      ?c.email,
      ?c.communeName,
      'desde ${formatDay(c.createdAt)}',
    ].join(' · ');
    return Card(
      child: ListTile(
        key: Key('client-${c.userId}'),
        leading: CircleAvatar(
          child: Icon(c.blocked ? Icons.no_accounts_outlined : Icons.person),
        ),
        title: Text(c.displayName),
        subtitle: Text(details),
        trailing: Text(
          c.visitsTotal == 1 ? '1 visita' : '${c.visitsTotal} visitas',
        ),
        onTap: c.blocked
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) => _ClientDetailDialog(userId: c.userId),
              ),
      ),
    );
  }
}

class _ClientDetailDialog extends ConsumerWidget {
  const new({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(adminClientDetailProvider(userId));
    return AlertDialog(
      title: Text(detail.value?.displayName ?? 'Cliente'),
      content: SizedBox(
        width: 480,
        child: switch (detail) {
          AsyncData(value: final d) => _DetailBody(d),
          AsyncError(:final error) => Text(
            friendlyError(error),
            key: const Key('client-detail-error'),
          ),
          _ => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
        },
      ),
      actions: [
        TextButton(
          key: const Key('client-detail-close'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class _DetailBody extends StatelessWidget {
  const new(this.d);

  final AdminClientDetail d;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statuses = d.visitsByStatus.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return SingleChildScrollView(
      key: const Key('client-detail'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Contacto', style: theme.textTheme.titleSmall),
          _Row(Icons.mail_outline, 'Correo', d.email ?? '—'),
          _Row(Icons.phone_outlined, 'Teléfono', d.phone ?? 'Sin teléfono'),
          _Row(Icons.place_outlined, 'Comuna', d.communeName ?? 'Sin comuna'),
          _Row(Icons.event_outlined, 'Cliente desde', formatDay(d.createdAt)),
          _Row(
            Icons.login,
            'Último ingreso',
            d.lastSignInAt == null ? '—' : formatDay(d.lastSignInAt!),
          ),
          _Row(
            Icons.volunteer_activism_outlined,
            'Fundación',
            d.foundationName ?? 'La por defecto',
          ),
          const Divider(height: 24),
          Text('Actividad', style: theme.textTheme.titleSmall),
          _Row(
            Icons.event_note_outlined,
            'Visitas',
            '${d.visitsTotal} (${d.urgentVisits} urgencias)',
            key: const Key('client-detail-visits'),
          ),
          for (final s in statuses)
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Text(
                '${VisitStatus.parse(s.key).label}: ${s.value}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          _Row(
            Icons.history,
            'Última visita',
            d.lastVisitAt == null ? '—' : formatDay(d.lastVisitAt!),
          ),
          _Row(
            Icons.payments_outlined,
            'Pagado en visitas',
            formatClp(d.paidTotal),
            key: const Key('client-detail-paid'),
          ),
          _Row(Icons.money_off, 'Cargos por cancelación', '${d.cancelFees}'),
          _Row(
            Icons.favorite_outline,
            'Donaciones',
            formatClp(d.donationsTotal),
          ),
          _Row(
            Icons.star_outline,
            'Calificación de los vets',
            d.ratingAvg == null
                ? 'Sin calificaciones'
                : '${d.ratingAvg!.toStringAsFixed(1).replaceAll('.', ',')} '
                      '(${d.ratingCount})',
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const new(this.icon, this.label, this.value, {super.key});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        SizedBox(width: 150, child: Text(label)),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
