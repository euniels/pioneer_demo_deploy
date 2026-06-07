import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/auth.dart';
import 'package:pioneerpath/src/services/role_service.dart';
import 'package:pioneerpath/src/services/user_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AuthService.logout();
  });

  test('logout clears restored session state', () async {
    await AuthService.logout();

    expect(AuthService.isLoggedIn, isFalse);
    expect(AuthService.currentRole, isNull);
    expect(AuthService.isLoggingOut, isFalse);
  });

  test('auth service exposes shared logout in-progress state', () {
    final source = File('lib/src/services/auth.dart').readAsStringSync();
    final api = File('lib/src/services/backend_api.dart').readAsStringSync();
    final dashboard = File(
      'lib/src/widgets/dashboard_layout.dart',
    ).readAsStringSync();
    final sidebar = File('lib/src/widgets/fleet_sidebar.dart').readAsStringSync();

    expect(source, contains('logoutInProgress'));
    expect(source, contains('_logoutFuture'));
    expect(source, contains('BackendApiService.setSessionTerminating(true)'));
    expect(source, contains('BackendApiService.setSessionTerminating(false)'));
    expect(api, contains('setSessionTerminating'));
    expect(api, contains('Session is signing out'));
    expect(dashboard, contains('AuthService.logoutInProgress.addListener'));
    expect(sidebar, contains('AuthService.logoutInProgress.addListener'));
  });

  test('managed role maps backend administrator roles to app role', () {
    final user = UserModel.fromJson({
      'id': 'u001',
      'username': 'admin',
      'fullName': 'System Administrator',
      'email': 'admin@pioneerpath.local',
      'role': 'super_administrator',
      'createdAt': '2024-01-01T00:00:00.000',
      'mustChangePassword': true,
    });

    expect(user.role, UserRole.admin);
    expect(user.managedRole, 'super_administrator');
    expect(user.mustChangePassword, isTrue);
  });

  test('saved user restore accepts legacy enum-style role strings', () {
    final user = UserModel.fromJson({
      'id': 'u001',
      'username': 'admin',
      'fullName': 'System Administrator',
      'email': 'admin@pioneerpath.local',
      'role': 'UserRole.admin',
      'createdAt': '2024-01-01T00:00:00.000',
    });

    expect(user.role, UserRole.admin);
  });
}
