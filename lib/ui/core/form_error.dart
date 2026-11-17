import 'package:flutter/material.dart';
import 'package:proyecto_felix/ui/core/info_banner.dart';

/// Mensaje de error de formulario (el lector de pantalla lo anuncia).
class FormError extends StatelessWidget {
  const new(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => InfoBanner(
    message: message,
    tone: BannerTone.error,
    textKey: const Key('form-error'),
    liveRegion: true,
  );
}

/// Columna centrada con ancho máximo, para formularios en Web y Windows.
///
/// En pantallas anchas el formulario va dentro de una tarjeta para que no
/// "flote" en medio de la ventana; en móvil ocupa todo el ancho.
class FormPage extends StatelessWidget {
  const new({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  /// Ancho desde el que el formulario se muestra dentro de una tarjeta.
  static const cardBreakpoint = 600.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= cardBreakpoint;
            final column = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            );
            return Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: wide ? 24 : 16,
                  vertical: wide ? 32 : 24,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wide ? 480 : 420),
                  child: wide
                      ? Card(
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: column,
                          ),
                        )
                      : column,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
