import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Recuerda qué usuario está en modo "recuperar contraseña", para que una
/// recarga de la web (o reabrir la app) lo siga llevando a /reset-password
/// (QA O-2). Se guarda en el mismo almacenamiento local que la sesión.
abstract interface class RecoveryFlagStore {
  /// Id del usuario en recuperación, o null.
  Future<String?> read();

  /// null borra la marca.
  Future<void> write(String? userId);
}

class SharedPrefsRecoveryFlagStore implements RecoveryFlagStore {
  const new();

  static const _key = 'felix.password_recovery_user';

  @override
  Future<String?> read() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_key);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (userId == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, userId);
      }
    } on Object {
      // Sin almacenamiento (modo privado): queda solo en memoria.
    }
  }
}

final recoveryFlagStoreProvider = Provider<RecoveryFlagStore>(
  (ref) => const SharedPrefsRecoveryFlagStore(),
);
