import 'package:flutter/material.dart';
import 'package:proyecto_felix/domain/models/visit.dart';

/// Etiqueta del estado de la visita (texto + color; no depende solo del
/// color para ser accesible).
class VisitStatusChip extends StatelessWidget {
  const new({required this.status, super.key});

  final VisitStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg, icon) = switch (status) {
      VisitStatus.completed => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_outline,
      ),
      _ when status.isOpen => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        Icons.schedule,
      ),
      _ => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.block,
      ),
    };
    return Semantics(
      label: 'Estado: ${status.label}',
      excludeSemantics: true,
      child: Container(
        key: Key('visit-status-${status.wire}'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                status.label,
                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Diálogo de confirmación con motivo opcional. Devuelve null si se cancela.
Future<String?> askReason(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _ReasonDialog(title: title, message: message, confirmLabel: confirmLabel),
);

class _ReasonDialog extends StatefulWidget {
  const new({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.message, key: const Key('reason-message')),
          const SizedBox(height: 12),
          TextField(
            key: const Key('reason-field'),
            controller: _reason,
            maxLength: 300,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Motivo (opcional)'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Volver'),
      ),
      FilledButton(
        key: const Key('reason-confirm'),
        onPressed: () => Navigator.of(context).pop(_reason.text),
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
