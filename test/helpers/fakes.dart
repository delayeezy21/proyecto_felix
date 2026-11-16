import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/app.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';

const configuredEnv = Env(
  supabaseUrl: 'http://127.0.0.1:54321',
  supabasePublishableKey: 'clave-de-prueba',
  mapProvider: MapProvider.osm,
  mapsApiKey: '',
);

const legalTest = LegalVersions(terms: 't-1', privacy: 'p-1');

class FakeAuthRepository implements AuthRepository {
  new({this._userId});

  String? _userId;
  final _changes = StreamController<String?>.broadcast();

  /// Si se define, la próxima operación falla con este error.
  AuthFailure? nextFailure;
  SignUpResult signUpResult = SignUpResult.confirmationRequired;
  final signInCalls = <(String, String)>[];
  final signUpCalls = <(String, String)>[];
  int googleCalls = 0;
  final resendCalls = <String>[];

  String? get userId => _userId;

  void emit(String? userId) {
    _userId = userId;
    _changes.add(userId);
  }

  void _maybeFail() {
    final failure = nextFailure;
    if (failure != null) {
      nextFailure = null;
      throw failure;
    }
  }

  @override
  Stream<String?> watchUserId() async* {
    yield _userId;
    yield* _changes.stream;
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    signInCalls.add((email, password));
    _maybeFail();
    emit('user-$email');
  }

  @override
  Future<SignUpResult> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    signUpCalls.add((email, password));
    _maybeFail();
    return signUpResult;
  }

  @override
  Future<void> resendConfirmation({required String email}) async {
    resendCalls.add(email);
    _maybeFail();
  }

  @override
  Future<void> signInWithGoogle() async {
    googleCalls++;
    _maybeFail();
  }

  @override
  Future<void> signOut() async => emit(null);
}

class RegistrationCall {
  const new({
    required this.role,
    required this.displayName,
    required this.phone,
    required this.legal,
    required this.marketing,
    this.communeId,
  });

  final AppRole role;
  final String displayName;
  final String? phone;
  final LegalVersions legal;
  final bool marketing;
  final int? communeId;
}

class FakeProfileRepository implements ProfileRepository {
  new(this._auth, {Map<String, Account>? accounts}) : accounts = accounts ?? {};

  final FakeAuthRepository _auth;
  final Map<String, Account> accounts;
  final registrationCalls = <RegistrationCall>[];
  ProfileFailure? nextFailure;

  @override
  Future<Account?> fetchAccount() async => accounts[_auth.userId];

  @override
  Future<LegalVersions> fetchLegalVersions() async => legalTest;

  @override
  Future<void> completeRegistration({
    required AppRole role,
    required String displayName,
    required String? phone,
    required LegalVersions legal,
    required bool marketingConsent,
    int? communeId,
  }) async {
    registrationCalls.add(
      RegistrationCall(
        role: role,
        displayName: displayName,
        phone: phone,
        legal: legal,
        marketing: marketingConsent,
        communeId: communeId,
      ),
    );
    final failure = nextFailure;
    if (failure != null) {
      nextFailure = null;
      throw failure;
    }
    accounts[_auth.userId!] = Account(
      role: role,
      displayName: displayName.trim(),
      vetStatus: role == AppRole.vet ? VetStatus.pending : null,
    );
  }
}

/// App completa con repositorios falsos.
Widget testApp({
  required FakeAuthRepository auth,
  required FakeProfileRepository profiles,
  FakeCatalogRepository? catalog,
  Env env = configuredEnv,
}) => ProviderScope(
  overrides: [
    envProvider.overrideWithValue(env),
    authRepositoryProvider.overrideWithValue(auth),
    profileRepositoryProvider.overrideWithValue(profiles),
    catalogRepositoryProvider.overrideWithValue(
      catalog ?? FakeCatalogRepository(),
    ),
  ],
  child: const FelixApp(),
);

/// Catálogos en memoria con datos mínimos.
class FakeCatalogRepository implements CatalogRepository {
  final regionList = const [
    Region(id: 13, name: 'Metropolitana de Santiago'),
    Region(id: 5, name: 'Valparaíso'),
  ];
  final communeList = const [
    Commune(id: 101, regionId: 13, name: 'Santiago'),
    Commune(id: 102, regionId: 13, name: 'Ñuñoa'),
    Commune(id: 201, regionId: 5, name: 'Viña del Mar'),
  ];
  final Map<CatalogKind, List<CatalogItem>> itemsByKind = {
    CatalogKind.species: [
      const CatalogItem(id: 1, slug: 'perro', name: 'Perro', active: true),
      const CatalogItem(id: 2, slug: 'gato', name: 'Gato', active: true),
    ],
    CatalogKind.specialties: [
      const CatalogItem(
        id: 1,
        slug: 'general',
        name: 'Medicina general',
        active: true,
      ),
    ],
  };
  List<Tariff> tariffList = [
    const Tariff(
      id: 1,
      specialtyName: 'Medicina general',
      basePrice: 25000,
      active: true,
    ),
  ];
  PricingConfig pricing = const PricingConfig(
    commissionPct: 15,
    foundationPct: 20,
    urgentPct: 30,
    perKm: 500,
    freeKm: 5,
    cancelFee: 5000,
  );
  final pricingVersions = <PricingConfig>[];
  final clinicList = <EmergencyClinic>[];
  CatalogFailure? nextFailure;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  @override
  Future<List<Region>> regions() async => regionList;

  @override
  Future<List<Commune>> communes(int regionId) async =>
      communeList.where((c) => c.regionId == regionId).toList();

  @override
  Future<List<CatalogItem>> items(CatalogKind kind) async =>
      List.of(itemsByKind[kind]!);

  @override
  Future<void> createItem(CatalogKind kind, String name) async {
    _maybeFail();
    final list = itemsByKind[kind]!;
    list.add(
      CatalogItem(
        id: list.length + 100,
        slug: slugify(name),
        name: name,
        active: true,
      ),
    );
  }

  @override
  Future<void> renameItem(CatalogKind kind, int id, String name) async {
    _maybeFail();
    final list = itemsByKind[kind]!;
    final i = list.indexWhere((e) => e.id == id);
    final old = list[i];
    list[i] = CatalogItem(
      id: old.id,
      slug: old.slug,
      name: name,
      active: old.active,
    );
  }

  @override
  Future<void> setItemActive(
    CatalogKind kind,
    int id, {
    required bool active,
  }) async {
    _maybeFail();
    final list = itemsByKind[kind]!;
    final i = list.indexWhere((e) => e.id == id);
    final old = list[i];
    list[i] = CatalogItem(
      id: old.id,
      slug: old.slug,
      name: old.name,
      active: active,
    );
  }

  @override
  Future<List<Tariff>> tariffs() async => List.of(tariffList);

  @override
  Future<void> updateTariffPrice(int id, int basePrice) async {
    _maybeFail();
    tariffList = tariffList.map((t) {
      if (t.id != id) return t;
      return Tariff(
        id: t.id,
        specialtyName: t.specialtyName,
        speciesName: t.speciesName,
        basePrice: basePrice,
        active: t.active,
      );
    }).toList();
  }

  @override
  Future<PricingConfig> currentPricing() async => pricing;

  @override
  Future<void> createPricingVersion(PricingConfig config) async {
    _maybeFail();
    pricingVersions.add(config);
    pricing = config;
  }

  @override
  Future<List<EmergencyClinic>> clinics() async => List.of(clinicList);

  @override
  Future<void> createClinic({
    required String name,
    required int communeId,
    required String address,
    required String phone,
  }) async {
    _maybeFail();
    clinicList.add(
      EmergencyClinic(
        id: 'c${clinicList.length}',
        name: name,
        communeId: communeId,
        communeName: communeList.firstWhere((c) => c.id == communeId).name,
        address: address,
        phone: phone,
        active: true,
      ),
    );
  }

  @override
  Future<void> setClinicActive(String id, {required bool active}) async {
    _maybeFail();
  }
}
