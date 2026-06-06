import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend_api.dart';
import 'role_service.dart';
import 'user_model.dart';
import 'web_session_channel.dart';

class AuthService {
  static UserModel? _currentUser;
  static String? _accessToken;
  static String? _refreshToken;
  static String? _lastAuthError;
  static VoidCallback? _sessionExpiredRedirect;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static final Map<String, String> _secureFallback = {};

  static const String _accessTokenKey = 'pioneer_access_token';
  static const String _refreshTokenKey = 'pioneer_refresh_token';
  static const String _accessExpiresKey = 'pioneer_access_expires_at';

  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier(
    ThemeMode.dark,
  );
  static final ValueNotifier<int> authStateVersion = ValueNotifier(0);

  static const Map<String, dynamic> _defaultPreferences = {
    'notifyTrips': true,
    'notifyMaintenance': true,
    'notifyBilling': true,
    'quietHours': '22:00 - 06:00',
    'dateFormat': 'yyyy-MM-dd',
    'distanceUnit': 'km',
    'timezone': 'Asia/Manila',
    'billingRate': '1250',
    'humidityThreshold': '75',
    'vehicleCategories': '6W, 10W, Trailer, Reefer',
  };

  static UserModel? get currentUserData => _currentUser;
  static String get currentUser => _currentUser?.username ?? '';
  static UserRole? get currentRole => _currentUser?.role;
  static bool get isLoggedIn => _currentUser != null;
  static bool get mustChangePassword =>
      _currentUser?.mustChangePassword == true;
  static String? get lastAuthError => _lastAuthError;

  static void setSessionExpiredRedirect(VoidCallback redirect) {
    _sessionExpiredRedirect = redirect;
  }

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    BackendApiService.configureAuthCallbacks(
      refreshAuth: refreshSession,
      onSessionExpired: _handleSessionExpired,
    );
    await initWebSessionChannel(onLogout: () async => _handleSessionExpired());

    final savedTheme = prefs.getString('theme_mode');
    if (savedTheme == 'dark') {
      themeMode.value = ThemeMode.dark;
    } else if (savedTheme == 'light') {
      themeMode.value = ThemeMode.light;
    }

    _accessToken = await _readSecure(_accessTokenKey);
    _refreshToken = await _readSecure(_refreshTokenKey);
    BackendApiService.setAccessToken(_accessToken);

    final userJson = prefs.getString('current_user');
    if (userJson == null || (_accessToken ?? '').isEmpty) {
      _currentUser = null;
      BackendApiService.setCurrentActorRole(null);
      return;
    }

    try {
      _currentUser = UserModel.fromJson(
        jsonDecode(userJson) as Map<String, dynamic>,
      );
      BackendApiService.setCurrentActorRole(currentManagedRole);
      unawaited(_refreshRestoredSession());
    } catch (_) {
      await _clearLocalSession(prefs);
    }
  }

  static Future<void> _refreshRestoredSession() async {
    final validSession = await refreshSession();
    if (validSession) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await _clearLocalSession(prefs);
    _sessionExpiredRedirect?.call();
  }

  static Future<bool> login(String username, String password) async {
    try {
      final backendUser = await BackendApiService.loginManagedUser(
        username,
        password,
      );
      _currentUser = UserModel.fromJson(backendUser);
      await _storeAuthTokens(backendUser['auth']);
      BackendApiService.setCurrentActorRole(currentManagedRole);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_user', jsonEncode(_currentUser!.toJson()));
      _lastAuthError = null;
      authStateVersion.value++;

      return true;
    } catch (error) {
      _lastAuthError = _friendlyAuthError(error);
      return false;
    }
  }

  static Future<bool> refreshSession() async {
    final token = _refreshToken ?? await _readSecure(_refreshTokenKey);
    if (token == null || token.trim().isEmpty) {
      return false;
    }

    try {
      final response = await BackendApiService.refreshAuthToken(token);
      await _storeAuthTokens(response['auth']);
      return (_accessToken ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    try {
      final response = await BackendApiService.changeManagedUserPassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      _currentUser = UserModel.fromJson(response);
      await _storeAuthTokens(response['auth']);
      BackendApiService.setCurrentActorRole(currentManagedRole);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_user', jsonEncode(_currentUser!.toJson()));
      _lastAuthError = null;
      authStateVersion.value++;

      return true;
    } catch (error) {
      _lastAuthError = _friendlyAuthError(error);
      return false;
    }
  }

  static Future<bool> requestPasswordReset(String email) async {
    try {
      await BackendApiService.requestPasswordReset(email);
      _lastAuthError = null;
      return true;
    } catch (error) {
      _lastAuthError = _friendlyAuthError(error);
      return false;
    }
  }

  static Future<bool> resetPasswordWithToken({
    required String email,
    required String token,
    required String password,
  }) async {
    try {
      final response = await BackendApiService.resetPasswordWithToken(
        email: email,
        token: token,
        password: password,
      );
      _currentUser = UserModel.fromJson(response);
      await _storeAuthTokens(response['auth']);
      BackendApiService.setCurrentActorRole(currentManagedRole);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_user', jsonEncode(_currentUser!.toJson()));
      _lastAuthError = null;
      authStateVersion.value++;
      return true;
    } catch (error) {
      _lastAuthError = _friendlyAuthError(error);
      return false;
    }
  }

  static Future<void> logout() async {
    final refreshToken = _refreshToken;
    if ((_accessToken ?? '').isNotEmpty) {
      try {
        await BackendApiService.logoutManagedUser(refreshToken);
      } catch (_) {}
    }

    _currentUser = null;
    _accessToken = null;
    _refreshToken = null;
    BackendApiService.setAccessToken(null);
    BackendApiService.setCurrentActorRole(null);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('current_user');
    await prefs.remove('remembered_user');
    await _deleteSecure(_accessTokenKey);
    await _deleteSecure(_refreshTokenKey);
    await _deleteSecure(_accessExpiresKey);
    notifyWebLogout();
    authStateVersion.value++;
  }

  static Future<String?> getRememberedUser() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('remembered_user');
  }

  static Future<void> setRememberedUser(String username) async {
    final prefs = await SharedPreferences.getInstance();
    if (username.isEmpty) {
      await prefs.remove('remembered_user');
    } else {
      await prefs.setString('remembered_user', username);
    }
  }

  static String get currentManagedRole {
    final explicit = _currentUser?.managedRole;
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    return _managedRoleForAppRole(_currentUser?.role);
  }

  static Future<void> setTheme(ThemeMode mode) async {
    themeMode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'theme_mode',
      mode == ThemeMode.dark ? 'dark' : 'light',
    );
  }

  static Future<void> updateCurrentUser({
    String? fullName,
    String? phone,
  }) async {
    final user = _currentUser;
    if (user == null) {
      return;
    }

    _currentUser = user.copyWith(
      fullName: fullName ?? user.fullName,
      phone: phone ?? user.phone,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_user', jsonEncode(_currentUser!.toJson()));
  }

  static Future<Map<String, dynamic>> getPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('user_preferences');
    if (raw == null || raw.isEmpty) {
      return Map<String, dynamic>.from(_defaultPreferences);
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return {..._defaultPreferences, ...decoded};
      }
    } catch (_) {}

    return Map<String, dynamic>.from(_defaultPreferences);
  }

  static Future<void> savePreferences(Map<String, dynamic> preferences) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'user_preferences',
      jsonEncode({..._defaultPreferences, ...preferences}),
    );
  }

  static Future<void> _storeAuthTokens(dynamic rawAuth) async {
    if (rawAuth is! Map) {
      throw const BackendApiException('Backend did not return auth tokens.');
    }

    final auth = rawAuth.map((key, value) => MapEntry(key.toString(), value));
    _accessToken = auth['accessToken']?.toString();
    _refreshToken = auth['refreshToken']?.toString();
    if ((_accessToken ?? '').isEmpty || (_refreshToken ?? '').isEmpty) {
      throw const BackendApiException(
        'Backend returned incomplete auth tokens.',
      );
    }

    BackendApiService.setAccessToken(_accessToken);
    await _writeSecure(_accessTokenKey, _accessToken!);
    await _writeSecure(_refreshTokenKey, _refreshToken!);
    final expiresAt = auth['expiresAt']?.toString();
    if (expiresAt != null && expiresAt.isNotEmpty) {
      await _writeSecure(_accessExpiresKey, expiresAt);
    }
  }

  static Future<String?> _readSecure(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (_) {
      return _secureFallback[key];
    }
  }

  static Future<void> _writeSecure(String key, String value) async {
    _secureFallback[key] = value;
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (_) {}
  }

  static Future<void> _deleteSecure(String key) async {
    _secureFallback.remove(key);
    try {
      await _secureStorage.delete(key: key);
    } catch (_) {}
  }

  static Future<void> _clearLocalSession(SharedPreferences prefs) async {
    _currentUser = null;
    _accessToken = null;
    _refreshToken = null;
    BackendApiService.setAccessToken(null);
    BackendApiService.setCurrentActorRole(null);
    await prefs.remove('current_user');
    await _deleteSecure(_accessTokenKey);
    await _deleteSecure(_refreshTokenKey);
    await _deleteSecure(_accessExpiresKey);
    authStateVersion.value++;
  }

  static void _handleSessionExpired() {
    _currentUser = null;
    _accessToken = null;
    _refreshToken = null;
    BackendApiService.setAccessToken(null);
    BackendApiService.setCurrentActorRole(null);
    _deleteSecure(_accessTokenKey);
    _deleteSecure(_refreshTokenKey);
    _deleteSecure(_accessExpiresKey);
    SharedPreferences.getInstance().then((prefs) {
      prefs.remove('current_user');
    });
    authStateVersion.value++;
    _sessionExpiredRedirect?.call();
  }

  static String _friendlyAuthError(Object error) {
    final text = error.toString();
    if (text.contains('429')) {
      return 'Too many sign-in attempts. Try again in 15 minutes.';
    }
    if (text.contains('423') || text.toLowerCase().contains('locked')) {
      return 'This account is locked. Contact your administrator.';
    }
    if (text.contains('403') ||
        text.toLowerCase().contains('inactive') ||
        text.toLowerCase().contains('deactivated')) {
      return 'This account is inactive. Contact your administrator.';
    }
    if (text.contains('422')) {
      return text.replaceFirst('BackendApiException: ', '');
    }
    return 'Invalid email or password.';
  }

  static String _managedRoleForAppRole(UserRole? role) {
    return switch (role) {
      UserRole.admin => 'super_administrator',
      UserRole.manager => 'fleet_manager',
      UserRole.finance => 'accounting_staff',
      UserRole.driver => 'driver',
      UserRole.client => 'client',
      UserRole.ceo => 'super_administrator',
      null => 'driver',
    };
  }
}
