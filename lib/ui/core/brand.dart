import 'package:flutter/material.dart';

/// Ícono de marca: huella dentro de un círculo con el color primario.
class BrandMark extends StatelessWidget {
  const new({this.size = 64, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.pets,
          size: size * 0.5,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// Encabezado de marca para pantallas de bienvenida y acceso.
class BrandHeader extends StatelessWidget {
  const new({
    this.tagline = 'Veterinarios a domicilio',
    this.showName = true,
    super.key,
  });

  final String tagline;

  /// Si es false solo muestra el ícono y el lema (útil cuando el AppBar ya
  /// dice "Felix").
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandMark(),
          const SizedBox(height: 12),
          if (showName) ...[
            Text(
              'Felix',
              style: theme.textTheme.displaySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
          ],
          Text(
            tagline,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
