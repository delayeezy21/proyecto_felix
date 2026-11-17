import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/data/repositories/owner_repositories.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';

void main() {
  group('validateMicrochip', () {
    test('vacío es válido (es opcional)', () {
      expect(validateMicrochip(null), isNull);
      expect(validateMicrochip(''), isNull);
    });

    test('exige 15 dígitos (ISO 11784/11785)', () {
      expect(validateMicrochip('152000000000001'), isNull);
      expect(validateMicrochip('152 000 000 000 001'), isNull);
      expect(validateMicrochip('15200000000000'), isNotNull);
      expect(validateMicrochip('15200000000000A'), isNotNull);
    });
  });

  group('approxAge', () {
    final now = DateTime(2026, 11, 17);

    test('en años y meses, en español', () {
      expect(approxAge(DateTime(2020, 3), now), '6 años');
      expect(approxAge(DateTime(2025, 11), now), '1 año');
      expect(approxAge(DateTime(2026, 6), now), '5 meses');
      expect(approxAge(DateTime(2026, 10), now), '1 mes');
      expect(approxAge(DateTime(2026, 11), now), 'Menos de 1 mes');
    });
  });

  group('PetDraft.toRow', () {
    test('solo columnas permitidas, con fecha ISO y microchip opcional', () {
      final row = PetDraft(
        name: '  Firulais ',
        speciesId: 1,
        breedId: 11,
        sex: PetSex.female,
        birthDateApprox: DateTime(2021, 7),
        microchip: ' ',
      ).toRow();
      expect(row.keys.toSet(), {
        'name',
        'species_id',
        'breed_id',
        'sex',
        'birth_date_approx',
        'sterilized',
        'microchip',
      });
      expect(row['name'], 'Firulais');
      expect(row['sex'], 'female');
      expect(row['birth_date_approx'], '2021-07-01');
      expect(row['microchip'], isNull);
    });
  });

  group('Address', () {
    test('toRow envía lat/lng (la BD deriva la geografía)', () {
      const draft = AddressDraft(
        label: ' Casa ',
        streetText: ' Av. Ficticia 123 ',
        details: '',
        communeId: 7,
        point: GeoPoint(-33.45, -70.6),
      );
      expect(draft.toRow(), {
        'label': 'Casa',
        'street_text': 'Av. Ficticia 123',
        'details': null,
        'commune_id': 7,
        'lat': -33.45,
        'lng': -70.6,
      });
    });

    test('addressFromRow lee la comuna embebida (sin N+1)', () {
      final a = addressFromRow({
        'id': 'a1',
        'label': 'Casa',
        'street_text': 'Av. Ficticia 123',
        'details': null,
        'commune_id': 7,
        'lat': -33.45,
        'lng': -70,
        'active': true,
        'communes': {'name': 'Ñuñoa', 'region_id': 13},
      });
      expect(a.communeName, 'Ñuñoa');
      expect(a.regionId, 13);
      expect(a.point, const GeoPoint(-33.45, -70));
    });

    test('petFromRow tolera especie oculta por desactivación', () {
      final p = petFromRow({
        'id': 'p1',
        'name': 'Pío',
        'species_id': 5,
        'breed_id': null,
        'sex': 'unknown',
        'birth_date_approx': null,
        'sterilized': false,
        'microchip': null,
        'active': true,
        'species': null,
        'breeds': null,
      });
      expect(p.speciesName, isNull);
      expect(p.sex, PetSex.unknown);
    });
  });

  test('GeoPoint.isInChile', () {
    expect(GeoPoint.santiago.isInChile, isTrue);
    expect(const GeoPoint(-27.12, -109.35).isInChile, isTrue); // Rapa Nui
    expect(const GeoPoint(40.4, -3.7).isInChile, isFalse);
    expect(const GeoPoint(-34.6, -58.4).isInChile, isFalse); // Buenos Aires
  });
}
