import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:paperless_api/paperless_api.dart';
import 'package:paperless_mobile/core/config/hive/hive_config.dart';
import 'package:paperless_mobile/core/database/tables/local_user_app_state.dart';
import 'package:paperless_mobile/core/factory/paperless_api_factory.dart';
import 'package:paperless_mobile/core/security/session_manager.dart';
import 'package:paperless_mobile/features/login/model/client_certificate.dart';
import 'package:paperless_mobile/features/login/model/login_form_credentials.dart';
import 'package:paperless_mobile/core/database/tables/local_user_account.dart';
import 'package:paperless_mobile/core/database/tables/user_credentials.dart';
import 'package:paperless_mobile/features/login/services/authentication_service.dart';
import 'package:paperless_mobile/core/database/tables/global_settings.dart';
import 'package:paperless_mobile/core/database/tables/local_user_settings.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

part 'authentication_state.dart';
part 'authentication_cubit.freezed.dart';

class AuthenticationCubit extends Cubit<AuthenticationState> {
  final LocalAuthenticationService _localAuthService;
  final PaperlessApiFactory _apiFactory;
  final SessionManager _sessionManager;

  AuthenticationCubit(
    this._localAuthService,
    this._apiFactory,
    this._sessionManager,
  ) : super(const AuthenticationState.unauthenticated());

  Future<void> login({
    required LoginFormCredentials credentials,
    required String serverUrl,
    ClientCertificate? clientCertificate,
  }) async {
    assert(credentials.username != null && credentials.password != null);
    final localUserId = "${credentials.username}@$serverUrl";

    await _addUser(
      localUserId,
      serverUrl,
      credentials,
      clientCertificate,
      _sessionManager,
    );

    final apiVersion = await _getApiVersion(_sessionManager.client);

    // Mark logged in user as currently active user.
    final globalSettings = Hive.box<GlobalSettings>(HiveBoxes.globalSettings).getValue()!;
    globalSettings.currentLoggedInUser = localUserId;
    await globalSettings.save();

    emit(
      AuthenticationState.authenticated(
        apiVersion: apiVersion,
        localUserId: localUserId,
      ),
    );
  }

  /// Switches to another account if it exists.
  Future<void> switchAccount(String localUserId) async {
    final globalSettings = Hive.box<GlobalSettings>(HiveBoxes.globalSettings).getValue()!;
    if (globalSettings.currentLoggedInUser == localUserId) {
      return;
    }
    final userAccountBox = Hive.box<LocalUserAccount>(HiveBoxes.localUserAccount);

    if (!userAccountBox.containsKey(localUserId)) {
      debugPrint("User $localUserId not yet registered.");
      return;
    }

    final account = userAccountBox.get(localUserId)!;

    if (account.settings.isBiometricAuthenticationEnabled) {
      final authenticated =
          await _localAuthService.authenticateLocalUser("Authenticate to switch your account.");
      if (!authenticated) {
        debugPrint("User not authenticated.");
        return;
      }
    }

    final credentialsBox = await _getUserCredentialsBox();
    if (!credentialsBox.containsKey(localUserId)) {
      await credentialsBox.close();
      debugPrint("Invalid authentication for $localUserId");
      return;
    }
    final credentials = credentialsBox.get(localUserId);
    await credentialsBox.close();

    await _resetExternalState();

    _sessionManager.updateSettings(
      authToken: credentials!.token,
      clientCertificate: credentials.clientCertificate,
      baseUrl: account.serverUrl,
    );

    globalSettings.currentLoggedInUser = localUserId;
    await globalSettings.save();

    final apiVersion = await _getApiVersion(_sessionManager.client);

    emit(AuthenticationState.authenticated(
      localUserId: localUserId,
      apiVersion: apiVersion,
    ));
  }

  Future<String> addAccount({
    required LoginFormCredentials credentials,
    required String serverUrl,
    ClientCertificate? clientCertificate,
    required bool enableBiometricAuthentication,
  }) async {
    assert(credentials.password != null && credentials.username != null);
    final localUserId = "${credentials.username}@$serverUrl";
    await _addUser(
      localUserId,
      serverUrl,
      credentials,
      clientCertificate,
      _sessionManager,
    );

    return localUserId;
  }

  Future<void> removeAccount(String userId) async {
    final globalSettings = Hive.box<GlobalSettings>(HiveBoxes.globalSettings).getValue()!;
    final userAccountBox = Hive.box<LocalUserAccount>(HiveBoxes.localUserAccount);
    final userCredentialsBox = await _getUserCredentialsBox();
    final userAppStateBox = Hive.box<LocalUserAppState>(HiveBoxes.localUserAppState);
    final currentUser = globalSettings.currentLoggedInUser;

    await userAccountBox.delete(userId);
    await userAppStateBox.delete(userId);
    await userCredentialsBox.delete(userId);
    await userCredentialsBox.close();

    if (currentUser == userId) {
      return logout();
    }
  }

  ///
  /// Performs a conditional hydration based on the local authentication success.
  ///
  Future<void> restoreSessionState() async {
    final globalSettings = Hive.box<GlobalSettings>(HiveBoxes.globalSettings).getValue()!;
    final localUserId = globalSettings.currentLoggedInUser;
    if (localUserId == null) {
      // If there is nothing to restore, we can quit here.
      return;
    }

    final userAccount = Hive.box<LocalUserAccount>(HiveBoxes.localUserAccount).get(localUserId)!;

    if (userAccount.settings.isBiometricAuthenticationEnabled) {
      final localAuthSuccess =
          await _localAuthService.authenticateLocalUser("Authenticate to log back in"); //TODO: INTL
      if (!localAuthSuccess) {
        emit(const AuthenticationState.requriresLocalAuthentication());
        return;
      }
    }
    final userCredentialsBox = await _getUserCredentialsBox();
    final authentication = userCredentialsBox.get(globalSettings.currentLoggedInUser!);

    await userCredentialsBox.close();

    if (authentication == null) {
      throw Exception("User should be authenticated but no authentication information was found.");
    }
    _sessionManager.updateSettings(
      clientCertificate: authentication.clientCertificate,
      authToken: authentication.token,
      baseUrl: userAccount.serverUrl,
    );
    final apiVersion = await _getApiVersion(_sessionManager.client);
    emit(
      AuthenticationState.authenticated(
        apiVersion: apiVersion,
        localUserId: localUserId,
      ),
    );
  }

  Future<void> logout() async {
    await _resetExternalState();
    final globalSettings = Hive.box<GlobalSettings>(HiveBoxes.globalSettings).getValue()!;
    globalSettings
      ..currentLoggedInUser = null
      ..save();
    emit(const AuthenticationState.unauthenticated());
  }

  Future<Uint8List> _getEncryptedBoxKey() async {
    const secureStorage = FlutterSecureStorage();
    if (!await secureStorage.containsKey(key: 'key')) {
      final key = Hive.generateSecureKey();

      await secureStorage.write(
        key: 'key',
        value: base64UrlEncode(key),
      );
    }
    final key = (await secureStorage.read(key: 'key'))!;
    return base64Decode(key);
  }

  Future<Box<UserCredentials>> _getUserCredentialsBox() async {
    final keyBytes = await _getEncryptedBoxKey();
    return Hive.openBox<UserCredentials>(
      HiveBoxes.localUserCredentials,
      encryptionCipher: HiveAesCipher(keyBytes),
    );
  }

  Future<void> _resetExternalState() async {
    _sessionManager.resetSettings();
    await HydratedBloc.storage.clear();
  }

  Future<int> _addUser(
    String localUserId,
    String serverUrl,
    LoginFormCredentials credentials,
    ClientCertificate? clientCert,
    SessionManager sessionManager,
  ) async {
    assert(credentials.username != null && credentials.password != null);

    sessionManager.updateSettings(
      baseUrl: serverUrl,
      clientCertificate: clientCert,
    );

    final authApi = _apiFactory.createAuthenticationApi(sessionManager.client);

    final token = await authApi.login(
      username: credentials.username!,
      password: credentials.password!,
    );

    sessionManager.updateSettings(
      baseUrl: serverUrl,
      clientCertificate: clientCert,
      authToken: token,
    );
    
    final userAccountBox = Hive.box<LocalUserAccount>(HiveBoxes.localUserAccount);
    final userStateBox = Hive.box<LocalUserAppState>(HiveBoxes.localUserAppState);

    if (userAccountBox.containsKey(localUserId)) {
      throw Exception("User with id $localUserId already exists!");
    }
    final apiVersion = await _getApiVersion(sessionManager.client);

    final serverUser = await _apiFactory
        .createUserApi(
          sessionManager.client,
          apiVersion: apiVersion,
        )
        .findCurrentUser();

    // Create user account
    await userAccountBox.put(
      localUserId,
      LocalUserAccount(
        id: localUserId,
        settings: LocalUserSettings(),
        serverUrl: serverUrl,
        paperlessUser: serverUser,
      ),
    );

    // Create user state
    await userStateBox.put(
      localUserId,
      LocalUserAppState(userId: localUserId),
    );

    // Save credentials in encrypted box
    final userCredentialsBox = await _getUserCredentialsBox();
    await userCredentialsBox.put(
      localUserId,
      UserCredentials(
        token: token,
        clientCertificate: clientCert,
      ),
    );
    userCredentialsBox.close();
    return serverUser.id;
  }

  Future<int> _getApiVersion(Dio dio) async {
    final response = await dio.get("/api/");
    return int.parse(response.headers.value('x-api-version') ?? "3");
  }
}
