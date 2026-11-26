import 'package:flutter/material.dart';
import 'package:proyecto_felix/core/theme/app_theme.dart';

/// Lista desplegable de Felix: el mismo campo redondeado del tema y un menú
/// flotante con esquinas redondeadas, sombra suave y la opción elegida
/// resaltada (en vez del menú plano por defecto de Material).
class AppDropdown<T> extends StatelessWidget {
  const new({
    required this.items,
    required this.onChanged,
    super.key,
    this.initialValue,
    this.decoration = const InputDecoration(),
    this.isExpanded = false,
    this.validator,
  });

  final List<DropdownMenuItem<T>>? items;
  final ValueChanged<T?>? onChanged;
  final T? initialValue;
  final InputDecoration decoration;
  final bool isExpanded;
  final FormFieldValidator<T>? validator;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropdownButtonFormField<T>(
      initialValue: initialValue,
      items: items,
      onChanged: onChanged,
      decoration: decoration,
      isExpanded: isExpanded,
      validator: validator,
      borderRadius: BorderRadius.circular(AppTheme.largeRadius),
      dropdownColor: scheme.surfaceContainerLow,
      elevation: 3,
      menuMaxHeight: 380,
      icon: Icon(
        Icons.keyboard_arrow_down_rounded,
        color: scheme.onSurfaceVariant,
      ),
      focusColor: Colors.transparent,
    );
  }
}
