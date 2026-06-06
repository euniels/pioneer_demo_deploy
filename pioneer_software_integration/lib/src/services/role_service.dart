enum UserRole { admin, ceo, finance, manager, driver, client }

class RolePermissions {
  static const Map<UserRole, List<String>> _allowedRoutes = {
    UserRole.admin: [
      '/dashboard',
      '/live-tracking',
      '/vehicles',
      '/client-tracking',
      '/drivers',
      '/dispatch-queue',
      '/routes',
      '/zones',
      '/trips',
      '/clients',
      '/billing',
      '/maintenance',
      '/delivery-confirm',
      '/notifications',
      '/statements-of-accounts',
      '/analytics',
      '/users',
      '/audit-logs',
      '/settings',
    ],
    UserRole.ceo: [
      '/dashboard',
      '/live-tracking',
      '/client-tracking',
      '/drivers',
      '/trips',
      '/statements-of-accounts',
      '/analytics',
      '/notifications',
      '/settings',
      '/ceo-profile',
    ],
    UserRole.finance: [
      '/billing',
      '/clients',
      '/delivery-confirm',
      '/client-tracking',
      '/statements-of-accounts',
      '/notifications',
      '/settings',
      '/finance-profile',
    ],
    UserRole.manager: [
      '/dashboard',
      '/live-tracking',
      '/client-tracking',
      '/vehicles',
      '/drivers',
      '/dispatch-queue',
      '/routes',
      '/zones',
      '/trips',
      '/maintenance',
      '/notifications',
      '/settings',
      '/manager-profile',
    ],
    UserRole.driver: [
      '/driver-dashboard',
      '/driver-map',
      '/driver-trips',
      '/driver-earnings',
      '/driver-vehicle',
      '/driver-profile',
      '/notifications',
      '/settings',
    ],
    UserRole.client: ['/client-tracking', '/notifications', '/settings'],
  };

  static bool canAccess(UserRole role, String route) {
    return _allowedRoutes[role]?.contains(route) ?? false;
  }

  static String getInitialRoute(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return '/dashboard';
      case UserRole.ceo:
        return '/dashboard';
      case UserRole.finance:
        return '/billing';
      case UserRole.manager:
        return '/dashboard';
      case UserRole.driver:
        return '/driver-dashboard';
      case UserRole.client:
        return '/client-tracking';
    }
  }

  static String getRoleDisplayName(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return 'Administrator';
      case UserRole.ceo:
        return 'Chief Executive Officer';
      case UserRole.finance:
        return 'Finance Officer';
      case UserRole.manager:
        return 'Fleet Manager';
      case UserRole.driver:
        return 'Driver';
      case UserRole.client:
        return 'Client';
    }
  }

  static String getProfileRoute(UserRole role) {
    switch (role) {
      case UserRole.admin:
        return '/settings';
      case UserRole.ceo:
        return '/ceo-profile';
      case UserRole.finance:
        return '/finance-profile';
      case UserRole.manager:
        return '/manager-profile';
      case UserRole.driver:
        return '/driver-profile';
      case UserRole.client:
        return '/settings';
    }
  }
}
