import 'package:flutter/material.dart';
import 'package:proyecto_felix/core/theme/app_theme.dart';

/// Tono de un [InfoBanner]: define colores e ícono por defecto.
enum BannerTone { info, success, warning, error }

/// Aviso destacado con ícono, usado para errores, confirmaciones y notas.
///
/// [textKey] se asigna al texto principal (los tests lo buscan por key).
class InfoBanner extends StatelessWidget {
  const new({
    required this.message,
    this.tone = BannerTone.info,
    this.title,
    this.icon,
    this.textKey,
    this.liveRegion = false,
    super.key,
  });

  final String message;
  final BannerTone tone;
  final String? title;
  final IconData? icon;
  final Key? textKey;

  /// Si es true, el lector de pantalla anuncia el aviso cuando aparece.
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground, defaultIcon) = switch (tone) {
      BannerTone.info => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        Icons.info_outline,
      ),
      BannerTone.success => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        Icons.check_circle_outline,
      ),
      BannerTone.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.lightbulb_outline,
      ),
      BannerTone.error => (
        scheme.errorContainer,
        scheme.onErrorContainer,
        Icons.error_outline,
      ),
    };
    final body = theme.textTheme.bodyMedium?.copyWith(color: foreground);
    return Semantics(
      liveRegion: liveRegion,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Icon(icon ?? defaultIcon, color: foreground, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null) ...[
                    Text(
                      title!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(message, key: textKey, style: body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
