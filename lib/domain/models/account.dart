import 'package:flutter/foundation.dart' show immutable;

/// Rol del usuario (vive en `public.user_roles`, nunca en `user_metadata`).
enum AppRole {
  owner,
  vet,
  foundation,
  admin;

  static AppRole? tryParse(String? value) => switch (value) {
    'owner' => AppRole.owner,
    'vet' => AppRole.vet,
    'foundation' => AppRole.foundation,
    'admin' => AppRole.admin,
    _ => null,
  };
}

/// Estado de aprobación de un veterinario.
enum VetStatus {
  pending,
  approved,
  rejected,
  suspended;

  static VetStatus parse(String? value) => switch (value) {
    'approved' => VetStatus.approved,
    'rejected' => VetStatus.rejected,
    'suspended' => VetStatus.suspended,
    _ => VetStatus.pending,
  };
}

/// Cuenta con registro completo (tiene rol y perfil).
@immutable
class Account {
  const new({required this.role, required this.displayName, this.vetStatus});

  final AppRole role;
  final String displayName;

  /// Solo para veterinarios.
  final VetStatus? vetStatus;

  @override
  bool operator ==(Object other) =>
      other is Account &&
      other.role == role &&
      other.displayName == displayName &&
      other.vetStatus == vetStatus;

  @override
  int get hashCode => Object.hash(role, displayName, vetStatus);
}

/// Estado de la sesión que usa el router para decidir a dónde ir.
sealed class SessionSnapshot {
  const new();
}

final class SessionLoading extends SessionSnapshot {
  const new();
}

final class SignedOut extends SessionSnapshot {
  const new();
}

/// No se pudo cargar la cuenta (error de red o del backend).
final class SessionFailed extends SessionSnapshot {
  const new();
}

/// Usuario autenticado. `account` es null si aún no completa el registro.
final class SignedIn extends SessionSnapshot {
  const new(this.account);

  final Account? account;
}

/// Versiones legales vigentes que el usuario acepta o ve al registrarse.
class LegalVersions {
  const new({required this.terms, required this.privacy});

  final String terms;
  final String privacy;
}
