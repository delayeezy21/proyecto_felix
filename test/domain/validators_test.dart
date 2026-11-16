import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/validators.dart';

void main() {
  group('Validators.email', () {
    test('acepta correos válidos (con espacios alrededor)', () {
      expect(Validators.email(' ana@correo.cl '), isNull);
    });
    test('rechaza vacío y formatos inválidos', () {
      expect(Validators.email(''), isNotNull);
      expect(Validators.email('ana@'), isNotNull);
      expect(Validators.email('ana correo.cl'), isNotNull);
    });
  });

  group('Validators.password (igual que config.toml)', () {
    test('acepta 8+ con minúscula, mayúscula y número', () {
      expect(Validators.password('Felix2026'), isNull);
    });
    test('rechaza cada regla incumplida', () {
      expect(Validators.password('Fe1ix'), 'Mínimo 8 caracteres');
      expect(Validators.password('FELIX2026'), contains('minúscula'));
      expect(Validators.password('felix2026'), contains('mayúscula'));
      expect(Validators.password('FelixFelix'), contains('número'));
    });
  });

  group('Validators.displayName (igual que el CHECK de la BD)', () {
    test('2 a 60 caracteres tras recortar', () {
      expect(Validators.displayName(' A '), isNotNull);
      expect(Validators.displayName('Ana'), isNull);
      expect(Validators.displayName('a' * 60), isNull);
      expect(Validators.displayName('a' * 61), isNotNull);
    });
  });

  group('Validators.phone (igual que el CHECK de la BD)', () {
    test('acepta formato chileno e internacional', () {
      expect(Validators.phone('+56 9 1234 5678', required: true), isNull);
      expect(Validators.phone('912345678', required: true), isNull);
    });
    test('vacío depende de si es obligatorio', () {
      expect(Validators.phone('', required: true), isNotNull);
      expect(Validators.phone('', required: false), isNull);
    });
    test('rechaza letras y largos inválidos', () {
      expect(Validators.phone('+56 9 ABCD', required: true), isNotNull);
      expect(Validators.phone('1234', required: true), isNotNull);
    });
  });
}
