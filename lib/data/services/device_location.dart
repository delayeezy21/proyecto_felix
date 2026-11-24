import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:proyecto_felix/domain/models/geo.dart';

/// Posición actual del dispositivo (Android, iOS, Web y Windows vía
/// `geolocator`). Devuelve null si no hay permiso, el servicio está apagado
/// o no responde a tiempo: quien la usa decide el respaldo.
abstract interface class DeviceLocation {
  Future<GeoPoint?> current();
}

class GeolocatorDeviceLocation implements DeviceLocation {
  const new();

  @override
  Future<GeoPoint?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 10),
        ),
      );
      return GeoPoint(p.latitude, p.longitude);
    } on Object {
      return null;
    }
  }
}

final deviceLocationProvider = Provider<DeviceLocation>(
  (ref) => const GeolocatorDeviceLocation(),
);
