import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/app.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/data/maps/geocoding_adapter.dart';
import 'package:proyecto_felix/data/maps/map_adapter.dart';
import 'package:proyecto_felix/data/maps/maps_providers.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/data/repositories/catalog_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/data/repositories/vet_repository.dart';
import 'package:proyecto_felix/data/services/account_blocked.dart';
import 'package:proyecto_felix/data/services/clock.dart';
import 'package:proyecto_felix/data/services/device_location.dart';
import 'package:proyecto_felix/data/services/platform_services.dart';
import 'package:proyecto_felix/data/services/recovery_flag_store.dart';
import 'package:proyecto_felix/domain/models/account.dart';
import 'package:proyecto_felix/domain/models/catalog.dart';
import 'package:proyecto_felix/domain/models/geo.dart';
import 'package:proyecto_felix/domain/models/pet.dart';
import 'package:proyecto_felix/domain/models/vet.dart';

import 'clinical_fakes.dart';
import 'owner_fakes.dart';
import 'pricing_fakes.dart';
import 'privacy_fakes.dart';
import 'urgent_fakes.dart';
import 'visit_fakes.dart';

export 'clinical_fakes.dart';
export 'owner_fakes.dart';
export 'pricing_fakes.dart';
export 'privacy_fakes.dart';
export 'urgent_fakes.dart';
export 'visit_fakes.dart';

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

  final resetCalls = <String>[];
  final passwordUpdates = <String>[];
  final _recovery = StreamController<void>.broadcast();

  /// Simula la vuelta desde el enlace de recuperación: hay sesión y llega el
  /// evento `passwordRecovery`.
  void emitRecovery(String userId) {
    emit(userId);
    _recovery.add(null);
  }

  @override
  Future<void> sendPasswordReset({required String email}) async {
    resetCalls.add(email);
    _maybeFail();
  }

  @override
  Stream<void> watchPasswordRecovery() => _recovery.stream;

  @override
  Future<void> updatePassword(String password) async {
    passwordUpdates.add(password);
    _maybeFail();
  }
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

  /// Si es true, fetchAccount falla (simula error de red o del backend).
  bool failFetch = false;

  /// Si es true, fetchAccount responde como el servidor con la cuenta
  /// bloqueada por una solicitud de eliminación (403 `account_blocked`).
  bool blocked = false;

  @override
  Future<Account?> fetchAccount() async {
    if (failFetch) throw const ProfileFailure('sin conexión');
    if (blocked) throw const AccountBlockedException();
    return accounts[_auth.userId];
  }

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
  FakeVetRepository? vets,
  FakeDocumentPicker? picker,
  FakeUrlOpener? opener,
  FakePetRepository? pets,
  FakeAddressRepository? addresses,
  GeocodingAdapter? geocoder,
  MapAdapter? map,
  FakeQuoteRepository? quotes,
  FakeFoundationRepository? foundations,
  FakeVisitRepository? visits,
  FakeVetAgendaRepository? agenda,
  FakeRecoveryFlagStore? recoveryStore,
  FakeClinicalRepository? clinical,
  FakeUrgentRepository? urgent,
  FakeLiveLocationService? live,
  FakeDeviceLocation? location,
  AppClock? clock,
  FakePrivacyRepository? privacy,
  FakeFileSaver? fileSaver,
  AccountBlockedSignal? blockedSignal,
  Env env = configuredEnv,
}) => ProviderScope(
  overrides: [
    envProvider.overrideWithValue(env),
    privacyRepositoryProvider.overrideWithValue(
      privacy ?? FakePrivacyRepository(),
    ),
    fileSaverProvider.overrideWithValue(fileSaver ?? FakeFileSaver()),
    if (blockedSignal != null)
      accountBlockedSignalProvider.overrideWithValue(blockedSignal),
    authRepositoryProvider.overrideWithValue(auth),
    profileRepositoryProvider.overrideWithValue(profiles),
    catalogRepositoryProvider.overrideWithValue(
      catalog ?? FakeCatalogRepository(),
    ),
    vetRepositoryProvider.overrideWithValue(vets ?? FakeVetRepository()),
    documentPickerProvider.overrideWithValue(picker ?? FakeDocumentPicker()),
    urlOpenerProvider.overrideWithValue(opener ?? FakeUrlOpener()),
    petRepositoryProvider.overrideWithValue(pets ?? FakePetRepository()),
    addressRepositoryProvider.overrideWithValue(
      addresses ?? FakeAddressRepository(),
    ),
    geocodingAdapterProvider.overrideWithValue(
      geocoder ?? FakeGeocodingAdapter(),
    ),
    mapAdapterProvider.overrideWithValue(map ?? FakeMapAdapter()),
    quoteRepositoryProvider.overrideWithValue(quotes ?? FakeQuoteRepository()),
    foundationRepositoryProvider.overrideWithValue(
      foundations ?? FakeFoundationRepository(),
    ),
    visitRepositoryProvider.overrideWithValue(visits ?? FakeVisitRepository()),
    vetAgendaRepositoryProvider.overrideWithValue(
      agenda ?? FakeVetAgendaRepository(),
    ),
    clinicalRepositoryProvider.overrideWithValue(
      clinical ?? FakeClinicalRepository(),
    ),
    urgentRepositoryProvider.overrideWithValue(
      urgent ?? FakeUrgentRepository(),
    ),
    liveLocationServiceProvider.overrideWithValue(
      live ?? FakeLiveLocationService(),
    ),
    deviceLocationProvider.overrideWithValue(location ?? FakeDeviceLocation()),
    // Reloj manual: sin latidos reales (refrescos, cuentas regresivas).
    clockProvider.overrideWithValue(clock ?? ManualClock()),
    recoveryFlagStoreProvider.overrideWithValue(
      recoveryStore ?? FakeRecoveryFlagStore(),
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
    Commune(
      id: 101,
      regionId: 13,
      name: 'Santiago',
      center: GeoPoint(-33.44, -70.65),
    ),
    Commune(
      id: 102,
      regionId: 13,
      name: 'Ñuñoa',
      center: GeoPoint(-33.46, -70.60),
    ),
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

  final breedList = const [
    Breed(id: 11, speciesId: 1, name: 'Beagle'),
    Breed(id: 12, speciesId: 1, name: 'Mestizo'),
    Breed(id: 21, speciesId: 2, name: 'Siamés'),
  ];

  @override
  Future<List<Breed>> breeds(int speciesId) async =>
      breedList.where((b) => b.speciesId == speciesId).toList();

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

/// Repositorio de vets en memoria (solicitud propia + revisión del admin).
class FakeVetRepository implements VetRepository {
  new({VetProfile? profile})
    : profile =
          profile ??
          const VetProfile(
            userId: 'v1',
            displayName: 'Dra. Vera',
            status: VetStatus.pending,
          );

  VetProfile profile;
  final species = <int>{};
  final specialties = <int>{};
  final blocks = <AvailabilityBlock>[];
  final documents = <VetDocument>[];
  final uploads = <(VetDocumentKind, String)>[];
  final reviews = <(String, bool, String?, String?)>[];
  final openedPaths = <String>[];
  List<VetApplicationSummary> pending = [];
  VetFailure? nextFailure;
  int submits = 0;

  /// Simula una subida lenta (para ver el indicador de carga).
  Duration uploadDelay = Duration.zero;

  void _maybeFail() {
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      throw f;
    }
  }

  VetProfile _copy({
    String? university,
    int? graduationYear,
    String? bio,
    bool? foreignDegree,
    String? code,
    DateTime? declaration,
    DateTime? submittedAt,
    VetStatus? status,
  }) => VetProfile(
    userId: profile.userId,
    displayName: profile.displayName,
    status: status ?? profile.status,
    bio: bio ?? profile.bio,
    university: university ?? profile.university,
    graduationYear: graduationYear ?? profile.graduationYear,
    foreignDegree: foreignDegree ?? profile.foreignDegree,
    titleVerificationCode: code ?? profile.titleVerificationCode,
    declarationAcceptedAt: declaration ?? profile.declarationAcceptedAt,
    submittedAt: submittedAt ?? profile.submittedAt,
    rejectionReason: profile.rejectionReason,
  );

  @override
  Future<VetProfile> myProfile() async => profile;

  @override
  Future<void> updateProfessionalData({
    required String? bio,
    required String? university,
    required int? graduationYear,
    required bool foreignDegree,
    required String? titleVerificationCode,
  }) async {
    _maybeFail();
    profile = _copy(
      bio: bio,
      university: university,
      graduationYear: graduationYear,
      foreignDegree: foreignDegree,
      code: titleVerificationCode,
    );
  }

  @override
  Future<void> updateBio(String? bio) async {
    _maybeFail();
    profile = _copy(bio: bio);
  }

  @override
  Future<void> acceptDeclaration() async {
    _maybeFail();
    profile = _copy(declaration: DateTime(2026, 11, 16));
  }

  @override
  Future<Set<int>> mySpeciesIds() async => {...species};

  @override
  Future<void> setSpecies(Set<int> ids) async {
    _maybeFail();
    species
      ..clear()
      ..addAll(ids);
  }

  @override
  Future<Set<int>> mySpecialtyIds() async => {...specialties};

  @override
  Future<void> setSpecialties(Set<int> ids) async {
    _maybeFail();
    specialties
      ..clear()
      ..addAll(ids);
  }

  @override
  Future<List<AvailabilityBlock>> myAvailability() async => List.of(blocks);

  @override
  Future<void> addAvailability(int weekday, int startMin, int endMin) async {
    _maybeFail();
    blocks.add(
      AvailabilityBlock(
        id: 'b${blocks.length}',
        weekday: weekday,
        startMin: startMin,
        endMin: endMin,
      ),
    );
  }

  @override
  Future<void> removeAvailability(String id) async {
    _maybeFail();
    blocks.removeWhere((b) => b.id == id);
  }

  @override
  Future<List<VetDocument>> myDocuments() async => List.of(documents);

  @override
  Future<void> uploadDocument(VetDocumentKind kind, PickedDocument file) async {
    if (uploadDelay > Duration.zero) await Future<void>.delayed(uploadDelay);
    _maybeFail();
    uploads.add((kind, file.name));
    documents.insert(
      0,
      VetDocument(
        id: 'd${documents.length}',
        kind: kind,
        mime: file.mime!,
        sizeBytes: file.bytes.length,
        uploadedAt: DateTime(2026, 11, 16),
        reviewStatus: 'pending',
        storagePath: 'v1/${file.name}',
      ),
    );
  }

  @override
  Future<void> submitApplication() async {
    _maybeFail();
    submits++;
    profile = _copy(
      submittedAt: DateTime(2026, 11, 16),
      status: VetStatus.pending,
    );
  }

  @override
  Future<List<VetApplicationSummary>> pendingApplications() async => pending;

  /// Resultados de la verificación asistida que devuelve applicationDetail.
  List<TitleVerification> verifications = [];

  /// Lo que agrega cada runTitleVerification (si es null, no cambia nada).
  List<TitleVerification>? nextVerificationResults;
  final verificationRuns = <String>[];

  @override
  Future<VetApplicationDetail> applicationDetail(String vetId) async =>
      VetApplicationDetail(
        profile: profile,
        documents: documents,
        speciesNames: const ['Perro'],
        specialtyNames: const ['Medicina general'],
        verifications: verifications,
      );

  @override
  Future<void> runTitleVerification(String vetId) async {
    verificationRuns.add(vetId);
    _maybeFail();
    final next = nextVerificationResults;
    if (next != null) verifications = next;
  }

  @override
  Future<String> documentUrl(String storagePath) async {
    openedPaths.add(storagePath);
    return 'https://example.test/$storagePath';
  }

  @override
  Future<void> review(
    String vetId, {
    required bool approve,
    String? reason,
    String? notes,
  }) async {
    _maybeFail();
    reviews.add((vetId, approve, reason, notes));
    pending = pending.where((p) => p.userId != vetId).toList();
  }
}

/// Selector de archivos falso: devuelve lo que se le indique.
class FakeDocumentPicker implements DocumentPicker {
  PickedDocument? next;

  @override
  Future<PickedDocument?> pick() async => next;
}

class FakeUrlOpener implements UrlOpener {
  final opened = <String>[];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

/// Marca de recuperación en memoria (simula el almacenamiento local).
class FakeRecoveryFlagStore implements RecoveryFlagStore {
  new({this.userId});

  String? userId;

  @override
  Future<String?> read() async => userId;

  @override
  Future<void> write(String? userId) async => this.userId = userId;
}
