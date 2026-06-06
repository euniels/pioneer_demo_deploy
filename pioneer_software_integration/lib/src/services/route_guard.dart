import 'auth.dart';
import 'crud_permissions.dart';
import 'role_service.dart';

class RouteGuard {
  /// Returns true if the current user can access [route].
  static bool canAccess(String route) {
    final role = AuthService.currentRole;
    if (role == null) return false;
    return RolePermissions.canAccess(role, route) &&
        CrudPermissions.canAccessRoute(route);
  }

  /// Returns the initial/home route for the current user.
  static String getHomeRoute() {
    final role = AuthService.currentRole;
    if (role == null) return '/login';
    return RolePermissions.getInitialRoute(role);
  }

  /// Call this inside Navigator onGenerateRoute or before push.
  /// Returns null if allowed, or a redirect path if blocked.
  static String? checkAccess(String route) {
    if (!AuthService.isLoggedIn) return '/login';
    if (AuthService.mustChangePassword && route != '/change-password') {
      return '/change-password';
    }
    if (!canAccess(route)) return getHomeRoute();
    return null; // allowed
  }
}
