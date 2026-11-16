import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

final documentPickerProvider = Provider<DocumentPicker>(
  (ref) => const PlatformDocumentPicker(),
);

final urlOpenerProvider = Provider<UrlOpener>(
  (ref) => const PlatformUrlOpener(),
);
