import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

Future<void>? _loading;

/// Carga el SDK JS de Google Maps con la clave de `--dart-define` (no queda en
/// `web/index.html` ni en el repo). Se llama una sola vez.
Future<void> ensureGoogleMapsLoaded(String apiKey) {
  final google = globalContext.getProperty<JSObject?>('google'.toJS);
  if (google != null && google.has('maps')) return Future.value();
  return _loading ??= _inject(apiKey);
}

Future<void> _inject(String apiKey) {
  final completer = Completer<void>();
  final script = web.HTMLScriptElement()
    ..src =
        'https://maps.googleapis.com/maps/api/js'
        '?key=${Uri.encodeQueryComponent(apiKey)}&language=es&region=CL'
    ..async = true
    ..onload = ((web.Event _) => completer.complete()).toJS
    ..onerror = ((web.Event _) {
      _loading = null;
      completer.completeError(StateError('No se pudo cargar Google Maps'));
    }).toJS;
  web.document.head!.append(script);
  return completer.future;
}
