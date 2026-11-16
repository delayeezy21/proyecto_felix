/// Validadores de formularios. Devuelven el mensaje de error o null si es
/// válido. Las reglas coinciden con `supabase/config.toml` y los CHECK de la BD.
abstract final class Validators {
  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final _phone = RegExp(r'^\+?[0-9 ]{8,15}$');

  static String? email(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return 'Ingresa tu correo';
    if (!_email.hasMatch(v)) return 'Correo no válido';
    return null;
  }

  /// Mínimo 8 caracteres, con minúsculas, mayúsculas y números.
  static String? password(String? value) {
    final v = value ?? '';
    if (v.length < 8) return 'Mínimo 8 caracteres';
    if (!v.contains(RegExp('[a-z]'))) return 'Incluye al menos una minúscula';
    if (!v.contains(RegExp('[A-Z]'))) return 'Incluye al menos una mayúscula';
    if (!v.contains(RegExp('[0-9]'))) return 'Incluye al menos un número';
    return null;
  }

  static String? displayName(String? value) {
    final v = value?.trim() ?? '';
    if (v.length < 2) return 'Ingresa al menos 2 caracteres';
    if (v.length > 60) return 'Máximo 60 caracteres';
    return null;
  }

  /// Teléfono chileno o internacional: +56 9 1234 5678.
  static String? phone(String? value, {required bool required}) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return required ? 'Ingresa tu teléfono' : null;
    if (!_phone.hasMatch(v)) return 'Teléfono no válido (ej: +56 9 1234 5678)';
    return null;
  }
}
