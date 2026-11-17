import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';

/// En Safari (iPhone), al volver el foco el archivo aún no está listo y
/// file_picker lo daba por cancelado a los 500 ms: la selección se perdía y
/// la carga "quedaba pegada". Se desactiva y se usa el evento `cancel`.
WebOptions pickerWebOptions() =>
    const FilePickerWebOptions(cancelUploadOnWindowBlur: false);
