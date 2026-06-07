import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/role_service.dart';
import 'package:pioneerpath/src/services/user_account_policy.dart';
import 'package:pioneerpath/src/services/user_model.dart';

void main() {
  final currentUser = UserModel(
    id: 'u-1',
    username: 'admin',
    fullName: 'Current Admin',
    email: 'admin@pioneerpath.local',
    role: UserRole.admin,
    createdAt: DateTime(2024),
    managedRole: 'super_administrator',
  );

  test('current user cannot deactivate, delete, or reset self', () {
    final policy = UserAccountPolicy.forUser(
      {
        'id': 'u-1',
        'email': 'admin@pioneerpath.local',
        'role': 'super_administrator',
        'status': 'active',
      },
      currentUser: currentUser,
      canEditUsers: true,
      canDeleteUsers: true,
    );

    expect(policy.isCurrentUser, isTrue);
    expect(policy.canResetPassword, isFalse);
    expect(policy.canDeactivate, isFalse);
    expect(policy.canHardDelete, isFalse);
    expect(policy.chips.map((chip) => chip.label), contains('Current user'));
  });

  test('super administrator cannot be permanently deleted from UI', () {
    final policy = UserAccountPolicy.forUser(
      {
        'id': 'u-2',
        'email': 'owner@pioneerpath.local',
        'role': 'super_administrator',
        'status': 'active',
      },
      currentUser: currentUser,
      canEditUsers: true,
      canDeleteUsers: true,
    );

    expect(policy.isSuperAdministrator, isTrue);
    expect(policy.canDeactivate, isTrue);
    expect(policy.canHardDelete, isFalse);
    expect(policy.deleteDisabledReason, contains('Super Administrator'));
  });

  test('inactive users show protected deactivate state but remain editable', () {
    final policy = UserAccountPolicy.forUser(
      {
        'id': 'u-3',
        'email': 'inactive@pioneerpath.local',
        'role': 'driver',
        'status': 'inactive',
      },
      currentUser: currentUser,
      canEditUsers: true,
      canDeleteUsers: true,
    );

    expect(policy.isInactive, isTrue);
    expect(policy.canEdit, isTrue);
    expect(policy.canDeactivate, isFalse);
    expect(policy.canResetPassword, isFalse);
    expect(policy.chips.map((chip) => chip.label), contains('Inactive'));
  });

  test('locked and must-change-password users expose status chips', () {
    final policy = UserAccountPolicy.forUser(
      {
        'id': 'u-4',
        'email': 'locked@pioneerpath.local',
        'role': 'system_administrator',
        'status': 'locked',
        'mustChangePassword': true,
      },
      currentUser: currentUser,
      canEditUsers: true,
      canDeleteUsers: true,
    );

    final labels = policy.chips.map((chip) => chip.label).toSet();
    expect(policy.isLocked, isTrue);
    expect(policy.isPrivileged, isTrue);
    expect(labels, contains('Locked'));
    expect(labels, contains('Privileged'));
    expect(labels, contains('Must change password'));
  });

  test('reset password is unavailable without edit permission', () {
    final policy = UserAccountPolicy.forUser(
      {
        'id': 'u-5',
        'email': 'driver@pioneerpath.local',
        'role': 'driver',
        'status': 'active',
      },
      currentUser: currentUser,
      canEditUsers: false,
      canDeleteUsers: false,
    );

    expect(policy.canEdit, isFalse);
    expect(policy.canResetPassword, isFalse);
    expect(policy.canDeactivate, isFalse);
    expect(policy.canHardDelete, isFalse);
  });
}
