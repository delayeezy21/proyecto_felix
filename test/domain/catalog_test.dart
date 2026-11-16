import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';

void main() {
  group(r'slugify (igual que el CHECK ^[a-z_]+$ de la BD)', () {
    test('quita tildes, eñes y espacios', () {
      expect(slugify('Hurón Doméstico'), 'huron_domestico');
      expect(slugify('Ñandú'), 'nandu');
      expect(slugify('  Medicina   general '), 'medicina_general');
    });

    test('elimina números y símbolos sobrantes', () {
      expect(slugify('Aves (exóticas) 2'), 'aves_exoticas');
    });
  });

  group('formatClp', () {
    test('separa miles con punto', () {
      expect(formatClp(0), r'$0');
      expect(formatClp(900), r'$900');
      expect(formatClp(25000), r'$25.000');
      expect(formatClp(1234567), r'$1.234.567');
      expect(formatClp(-4500), r'-$4.500');
    });
  });
}
