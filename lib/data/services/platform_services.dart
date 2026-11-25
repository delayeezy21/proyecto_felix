import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/data/services/picker_web_options_stub.dart'
    if (dart.library.js_interop) 'package:proyecto_felix/data/services/picker_web_options_web.dart';
import 'package:proyecto_felix/domain/models/vet.dart';
import 'package:url_launcher/url_launcher.dart';

/// Elegir un documento del dispositivo (se reemplaza en los tests).
abstract interface class DocumentPicker {
  Future<PickedDocument?> pick();
}

class PlatformDocumentPicker implements DocumentPicker {
  const new();

  @override
  Future<PickedDocument?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
      webOptions: pickerWebOptions(),
    );
    if (file == null) return null;
    return PickedDocument(name: file.name, bytes: await file.readAsBytes());
  }
}

/// Abrir un enlace externo (documento firmado, sitio de verificación).
abstract interface class UrlOpener {
  Future<bool> open(String url);
}

class PlatformUrlOpener implements UrlOpener {
  const new();

  @override
  Future<bool> open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Guardar un archivo generado por la app (exportación de mis datos).
abstract interface class FileSaver {
  /// Devuelve false si el usuario canceló el diálogo.
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  });
}

/// file_picker (ya era dependencia): diálogo "Guardar como" en Windows,
/// selector del sistema en Android e iOS y descarga del navegador en Web.
class PlatformFileSaver implements FileSaver {
  const new();

  @override
  Future<bool> save({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    final uri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      dialogTitle: 'Guardar mis datos',
    );
    // En Web se descarga directo y file_picker devuelve null (no cancela).
    return uri != null || kIsWeb;
  }
}

final fileSaverProvider = Provider<FileSaver>(
  (ref) => const PlatformFileSaver(),
);

final documentPickerProvider = Provider<DocumentPicker>(
  (ref) => const PlatformDocumentPicker(),
);

final urlOpenerProvider = Provider<UrlOpener>(
  (ref) => const PlatformUrlOpener(),
);
