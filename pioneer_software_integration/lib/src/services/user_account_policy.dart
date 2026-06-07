import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'user_model.dart';

class UserAccountStatusChip {
  const UserAccountStatusChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;
}

class UserAccountPolicy {
  const UserAccountPolicy({
    required this.isCurrentUser,
    required this.isSuperAdministrator,
    required this.isPrivileged,
    required this.isInactive,
    required this.isLocked,
    required this.mustChangePassword,
    required this.canEdit,
    required this.canResetPassword,
    required this.canDeactivate,
    required this.canHardDelete,
    required this.chips,
    required this.editDisabledReason,
    required this.resetPasswordDisabledReason,
    required this.deactivateDisabledReason,
    required this.deleteDisabledReason,
  });

  factory UserAccountPolicy.forUser(
    Map<String, dynamic> user, {
    required UserModel? currentUser,
    required bool canEditUsers,
    required bool canDeleteUsers,
  }) {
    final status = (user['status'] ?? 'active').toString().toLowerCase();
    final role = _roleOf(user);
    final isCurrentUser = _isCurrent(user, currentUser);
    final isSuperAdministrator = role == 'super_administrator';
    final isPrivileged =
        isSuperAdministrator || role == 'system_administrator';
    final isInactive = status == 'inactive';
    final isLocked = status == 'locked';
    final mustChangePassword = user['mustChangePassword'] == true;
    final canEdit = canEditUsers;
    final canResetPassword = canEditUsers && !isCurrentUser && !isInactive;
    final canDeactivate = canDeleteUsers && !isCurrentUser && !isInactive;
    final canHardDelete =
        canDeleteUsers && !isCurrentUser && !isSuperAdministrator;

    return UserAccountPolicy(
      isCurrentUser: isCurrentUser,
      isSuperAdministrator: isSuperAdministrator,
      isPrivileged: isPrivileged,
      isInactive: isInactive,
      isLocked: isLocked,
      mustChangePassword: mustChangePassword,
      canEdit: canEdit,
      canResetPassword: canResetPassword,
      canDeactivate: canDeactivate,
      canHardDelete: canHardDelete,
      chips: _chips(
        isCurrentUser: isCurrentUser,
        isPrivileged: isPrivileged,
        isInactive: isInactive,
        isLocked: isLocked,
        mustChangePassword: mustChangePassword,
      ),
      editDisabledReason:
          'Your role cannot edit user accounts in PioneerPath.',
      resetPasswordDisabledReason: isCurrentUser
          ? 'Use your profile password flow for your own account.'
          : isInactive
          ? 'Inactive accounts must be reactivated before password reset.'
          : 'Your role cannot reset user passwords.',
      deactivateDisabledReason: isCurrentUser
          ? 'You cannot deactivate your own active session account.'
          : isInactive
          ? 'This account is already inactive.'
          : 'Your role cannot deactivate user accounts.',
      deleteDisabledReason: isCurrentUser
          ? 'You cannot permanently delete your own active session account.'
          : isSuperAdministrator
          ? 'Super Administrator accounts can only be deactivated.'
          : 'Your role cannot permanently delete user accounts.',
    );
  }

  final bool isCurrentUser;
  final bool isSuperAdministrator;
  final bool isPrivileged;
  final bool isInactive;
  final bool isLocked;
  final bool mustChangePassword;
  final bool canEdit;
  final bool canResetPassword;
  final bool canDeactivate;
  final bool canHardDelete;
  final List<UserAccountStatusChip> chips;
  final String editDisabledReason;
  final String resetPasswordDisabledReason;
  final String deactivateDisabledReason;
  final String deleteDisabledReason;
}

String _roleOf(Map<String, dynamic> user) {
  final raw = user['role'] ?? user['managedRole'] ?? user['roleLabel'];
  final normalized = raw?.toString().toLowerCase().trim() ?? '';
  return normalized.replaceAll(RegExp(r'[\s-]+'), '_');
}

bool _isCurrent(Map<String, dynamic> user, UserModel? currentUser) {
  if (currentUser == null) {
    return false;
  }
  final id = user['id']?.toString().trim() ?? '';
  final email = user['email']?.toString().trim().toLowerCase() ?? '';
  return (id.isNotEmpty && id == currentUser.id) ||
      (email.isNotEmpty && email == currentUser.email.toLowerCase());
}

List<UserAccountStatusChip> _chips({
  required bool isCurrentUser,
  required bool isPrivileged,
  required bool isInactive,
  required bool isLocked,
  required bool mustChangePassword,
}) {
  return [
    if (isCurrentUser)
      const UserAccountStatusChip(
        label: 'Current user',
        color: AppTheme.infoBlue,
        icon: Icons.verified_user_rounded,
      ),
    if (isPrivileged)
      const UserAccountStatusChip(
        label: 'Privileged',
        color: AppTheme.purpleAccent,
        icon: Icons.admin_panel_settings_rounded,
      ),
    if (isLocked)
      const UserAccountStatusChip(
        label: 'Locked',
        color: AppTheme.errorRed,
        icon: Icons.lock_rounded,
      ),
    if (isInactive)
      const UserAccountStatusChip(
        label: 'Inactive',
        color: AppTheme.neutralGray,
        icon: Icons.block_rounded,
      ),
    if (mustChangePassword)
      const UserAccountStatusChip(
        label: 'Must change password',
        color: AppTheme.warningOrange,
        icon: Icons.key_rounded,
      ),
  ];
}
