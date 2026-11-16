import 'package:flutter/material.dart';
import 'package:proyecto_felix/ui/core/brand.dart';

class SplashView extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandMark(size: 80),
            SizedBox(height: 32),
            SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                semanticsLabel: 'Cargando',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
