import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/address.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/ui/features/owner/view_models/owner_providers.dart';

import '../helpers/fakes.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;
  late FakeAddressRepository addresses;
  late FakeGeocodingAdapter geocoder;
  late FakeMapAdapter map;

  setUp(() {
    auth = FakeAuthRepository(userId: 'o1');
    profiles = FakeProfileRepository(
      auth,
      accounts: {'o1': const Account(role: AppRole.owner, displayName: 'Ana')},
    );
    addresses = FakeAddressRepository();
    geocoder = FakeGeocodingAdapter();
    map = FakeMapAdapter();
  });

  Future<void> openNewAddress(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        auth: auth,
        profiles: profiles,
        addresses: addresses,
        geocoder: geocoder,
        map: map,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direcciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('address-add')));
    await tester.pumpAndSettle();
  }

  Future<void> chooseCommune(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('address-region')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metropolitana de Santiago').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('address-commune-13')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ñuñoa').last);
    await tester.pumpAndSettle();
  }

  const debounce = AddressSearchController.debounce;

  testWidgets('la búsqueda espera a que el usuario deje de escribir', (
    tester,
  ) async {
    await openNewAddress(tester);
    final street = find.byKey(const Key('address-street'));
    await tester.enterText(street, 'Av');
    await tester.pump(debounce * 2);
    expect(geocoder.searches, isEmpty, reason: 'menos de 3 letras');

    for (final text in ['Av. F', 'Av. Fic', 'Av. Ficticia']) {
      await tester.enterText(street, text);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(geocoder.searches, isEmpty, reason: 'aún dentro del debounce');
    await tester.pump(debounce);
    await tester.pump();
    expect(geocoder.searches, ['Av. Ficticia']);
    expect(find.byKey(const Key('address-suggestion-0')), findsOneWidget);
  });

  testWidgets('la búsqueda se acota a la comuna elegida', (tester) async {
    await openNewAddress(tester);
    await chooseCommune(tester);
    geocoder.searches.clear(); // el centro de la comuna también consulta
    await tester.enterText(
      find.byKey(const Key('address-street')),
      'Av. Ficticia',
    );
    await tester.pump(debounce);
    await tester.pump();
    expect(geocoder.searches, ['Av. Ficticia, Ñuñoa']);
  });

  testWidgets('elegir una sugerencia completa la calle y marca el punto', (
    tester,
  ) async {
    await openNewAddress(tester);
    await tester.enterText(find.byKey(const Key('address-street')), 'Av. Fic');
    await tester.pump(debounce);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('address-suggestion-1')));
    await tester.pumpAndSettle();

    expect(find.text('Av. Ficticia 456'), findsOneWidget);
    expect(find.byKey(const Key('address-suggestion-0')), findsNothing);
    expect(map.lastMarkers.single.point, geocoder.results[1].point);
    expect(map.animations.last, geocoder.results[1].point);
    expect(
      find.text('Punto marcado. Toca otro lugar del mapa para corregirlo.'),
      findsOneWidget,
    );
  });

  testWidgets('tocar el mapa marca el punto y sugiere la dirección cercana', (
    tester,
  ) async {
    await openNewAddress(tester);
    expect(map.lastMarkers, isEmpty);
    await tester.tap(find.byKey(const Key('fake-map')));
    await tester.pump();
    expect(map.lastMarkers.single.point, map.tapPoint);
    expect(geocoder.reverses, isEmpty, reason: 'debounce del inverso');

    await tester.pump(ReverseGeocodeController.debounce);
    await tester.pump();
    expect(geocoder.reverses, [map.tapPoint]);
    expect(find.text('Cerca de: Pasaje Inventado 77'), findsOneWidget);
    await tester.tap(find.byKey(const Key('address-use-nearby')));
    await tester.pump();
    expect(find.text('Pasaje Inventado 77'), findsOneWidget);
  });

  testWidgets('guardar sin punto en el mapa muestra un error', (tester) async {
    await openNewAddress(tester);
    await chooseCommune(tester);
    await tester.enterText(
      find.byKey(const Key('address-street')),
      'Calle Falsa 123',
    );
    await tester.tap(find.byKey(const Key('address-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('form-error')), findsOneWidget);
    expect(addresses.created, isEmpty);
  });

  testWidgets('guarda la dirección con comuna, coordenadas y detalle', (
    tester,
  ) async {
    await openNewAddress(tester);
    await chooseCommune(tester);
    await tester.enterText(
      find.byKey(const Key('address-street')),
      'Calle Falsa 123',
    );
    await tester.tap(find.byKey(const Key('fake-map')));
    await tester.enterText(find.byKey(const Key('address-details')), 'Depto 4');
    await tester.tap(find.byKey(const Key('address-save')));
    await tester.pumpAndSettle();

    final d = addresses.created.single;
    expect(d.label, 'Casa');
    expect(d.streetText, 'Calle Falsa 123');
    expect(d.details, 'Depto 4');
    expect(d.communeId, 102);
    expect(d.point, map.tapPoint);
    expect(d.toRow()['lat'], map.tapPoint.lat);
    // Vuelve al inicio con la lista actualizada.
    expect(find.text('Mis direcciones'), findsOneWidget);
    expect(find.text('Casa'), findsOneWidget);
  });

  testWidgets('si el buscador falla, se puede marcar el punto en el mapa', (
    tester,
  ) async {
    geocoder.fail = true;
    await openNewAddress(tester);
    await chooseCommune(tester);
    await tester.enterText(
      find.byKey(const Key('address-street')),
      'Calle Falsa 123',
    );
    await tester.pump(debounce);
    await tester.pump();
    expect(find.byKey(const Key('address-search-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('fake-map')));
    await tester.tap(find.byKey(const Key('address-save')));
    await tester.pumpAndSettle();
    expect(addresses.created, hasLength(1));
  });

  testWidgets('edita y desactiva una dirección existente', (tester) async {
    addresses.addresses.add(
      const Address(
        id: 'a1',
        label: 'Trabajo',
        streetText: 'Av. Inventada 10',
        communeId: 102,
        communeName: 'Ñuñoa',
        regionId: 13,
        point: GeoPoint(-33.45, -70.60),
        active: true,
      ),
    );
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        auth: auth,
        profiles: profiles,
        addresses: addresses,
        geocoder: geocoder,
        map: map,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direcciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('address-a1')));
    await tester.pumpAndSettle();

    expect(map.lastMarkers.single.point, const GeoPoint(-33.45, -70.60));
    await tester.enterText(find.byKey(const Key('address-label')), 'Oficina');
    await tester.tap(find.byKey(const Key('address-save')));
    await tester.pumpAndSettle();
    expect(addresses.updated.single.$1, 'a1');
    expect(addresses.updated.single.$2.label, 'Oficina');

    await tester.tap(find.byKey(const Key('address-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('address-toggle-active')));
    await tester.pumpAndSettle();
    expect(addresses.addresses.single.active, isFalse);
    expect(find.textContaining('Desactivada'), findsOneWidget);
  });
}
