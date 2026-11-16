import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proyecto_felix/app.dart';
import 'package:proyecto_felix/core/config/env.dart';
import 'package:proyecto_felix/core/config/env_provider.dart';
import 'package:proyecto_felix/data/providers.dart';
import 'package:proyecto_felix/data/repositories/auth_repository.dart';
import 'package:proyecto_felix/data/repositories/profile_repository.dart';
import 'package:proyecto_felix/domain/models/account.dart';

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
  });

  final AppRole role;
  final String displayName;
  final String? phone;
  final LegalVersions legal;
  final bool marketing;
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
  }) async {
    registrationCalls.add(
      RegistrationCall(
        role: role,
        displayName: displayName,
        phone: phone,
        legal: legal,
        marketing: marketingConsent,
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
  Env env = configuredEnv,
}) => ProviderScope(
  overrides: [
    envProvider.overrideWithValue(env),
    authRepositoryProvider.overrideWithValue(auth),
    profileRepositoryProvider.overrideWithValue(profiles),
  ],
  child: const FelixApp(),
);
