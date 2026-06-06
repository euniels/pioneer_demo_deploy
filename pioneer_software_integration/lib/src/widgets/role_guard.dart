import 'package:flutter/material.dart';
import '../services/auth.dart';
import '../services/role_service.dart';

/// Renders [child] only when the current user's role is in [allowedRoles].
/// Shows [fallback] (default: empty SizedBox) otherwise.
///
/// Usage:
/// ```dart
/// RoleGuard(
///   allowedRoles: [UserRole.admin, UserRole.manager],
///   child: DeleteButton(),
///   fallback: SizedBox.shrink(),
/// )
/// ```
class RoleGuard extends StatelessWidget {
  final List<UserRole> allowedRoles;
  final Widget child;
  final Widget? fallback;

  const RoleGuard({
    super.key,
    required this.allowedRoles,
    required this.child,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final role = AuthService.currentRole;
    if (role != null && allowedRoles.contains(role)) {
      return child;
    }
    return fallback ?? const SizedBox.shrink();
  }
}

/// Renders [child] only when the current user has exactly [role].
/// Shows [fallback] (default: empty SizedBox) otherwise.
///
/// Usage:
/// ```dart
/// RoleOnly(
///   role: UserRole.driver,
///   child: DriverEarningsWidget(),
/// )
/// ```
class RoleOnly extends StatelessWidget {
  final UserRole role;
  final Widget child;
  final Widget? fallback;

  const RoleOnly({
    super.key,
    required this.role,
    required this.child,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    if (AuthService.currentRole == role) return child;
    return fallback ?? const SizedBox.shrink();
  }
}

/// Renders [child] only when the current user is NOT in [excludedRoles].
/// Useful for hiding admin-only controls from other roles.
///
/// Usage:
/// ```dart
/// RoleExclude(
///   excludedRoles: [UserRole.driver],
///   child: AdminPanel(),
/// )
/// ```
class RoleExclude extends StatelessWidget {
  final List<UserRole> excludedRoles;
  final Widget child;
  final Widget? fallback;

  const RoleExclude({
    super.key,
    required this.excludedRoles,
    required this.child,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final role = AuthService.currentRole;
    if (role != null && !excludedRoles.contains(role)) {
      return child;
    }
    return fallback ?? const SizedBox.shrink();
  }
}

/// A mixin that adds role-check helpers to any State class.
///
/// Usage:
/// ```dart
/// class _MyPageState extends State<MyPage> with RoleChecks {
///   @override
///   Widget build(BuildContext context) {
///     if (isAdmin) { ... }
///     if (hasRole([UserRole.admin, UserRole.manager])) { ... }
///   }
/// }
/// ```
mixin RoleChecks {
  UserRole? get currentRole => AuthService.currentRole;

  bool get isAdmin => currentRole == UserRole.admin;
  bool get isCeo => currentRole == UserRole.ceo;
  bool get isFinance => currentRole == UserRole.finance;
  bool get isManager => currentRole == UserRole.manager;
  bool get isDriver => currentRole == UserRole.driver;
  bool get isClient => currentRole == UserRole.client;

  bool hasRole(List<UserRole> roles) =>
      currentRole != null && roles.contains(currentRole);

  bool lacksRole(List<UserRole> roles) =>
      currentRole == null || !roles.contains(currentRole);
}
