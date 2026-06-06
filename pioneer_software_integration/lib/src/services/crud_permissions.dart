import 'auth.dart';

enum CrudEntity {
  users,
  settings,
  vehicles,
  drivers,
  trips,
  routes,
  zones,
  clients,
  maintenance,
  invoices,
  billing,
  dispatch,
}

class CrudPermissions {
  const CrudPermissions._();

  static String get role => AuthService.currentManagedRole;

  static bool get isSuperAdmin => role == 'super_administrator';
  static bool get isSystemAdmin => role == 'system_administrator';

  static bool canCreate(CrudEntity entity) => _can(entity, 'create');
  static bool canEdit(CrudEntity entity) => _can(entity, 'edit');
  static bool canDelete(CrudEntity entity) => _can(entity, 'delete');

  static bool get canReviewGeoTabWriteBack => isSuperAdmin || isSystemAdmin;

  static bool canRead(CrudEntity entity) {
    if (isSuperAdmin || isSystemAdmin)
      return entity != CrudEntity.settings || isSuperAdmin;
    return switch (role) {
      'fleet_manager' => entity != CrudEntity.settings,
      'dispatcher' => {
        CrudEntity.trips,
        CrudEntity.vehicles,
        CrudEntity.drivers,
        CrudEntity.routes,
        CrudEntity.clients,
        CrudEntity.dispatch,
      }.contains(entity),
      'driver' => {CrudEntity.trips}.contains(entity),
      'accounting_staff' => {
        CrudEntity.invoices,
        CrudEntity.billing,
        CrudEntity.trips,
        CrudEntity.vehicles,
        CrudEntity.clients,
      }.contains(entity),
      _ => false,
    };
  }

  static bool canAccessRoute(String route) {
    if (isSuperAdmin) return true;
    if (isSystemAdmin) return true;

    return switch (role) {
      'fleet_manager' => {
        '/dashboard',
        '/live-tracking',
        '/client-tracking',
        '/vehicles',
        '/drivers',
        '/dispatch-queue',
        '/routes',
        '/zones',
        '/trips',
        '/clients',
        '/billing',
        '/maintenance',
        '/notifications',
        '/statements-of-accounts',
        '/analytics',
        '/users',
        '/manager-profile',
      }.contains(route),
      'dispatcher' => {
        '/dashboard',
        '/live-tracking',
        '/client-tracking',
        '/vehicles',
        '/drivers',
        '/dispatch-queue',
        '/routes',
        '/trips',
        '/clients',
        '/notifications',
        '/analytics',
      }.contains(route),
      'accounting_staff' => {
        '/billing',
        '/clients',
        '/trips',
        '/vehicles',
        '/statements-of-accounts',
        '/notifications',
        '/finance-profile',
      }.contains(route),
      'driver' => {
        '/driver-dashboard',
        '/driver-map',
        '/driver-trips',
        '/driver-vehicle',
        '/driver-profile',
        '/notifications',
      }.contains(route),
      _ => false,
    };
  }

  static bool _can(CrudEntity entity, String action) {
    if (isSuperAdmin) return true;
    if (isSystemAdmin) return entity != CrudEntity.settings;

    if (role == 'fleet_manager') {
      if (action == 'delete') return false;
      return {
        CrudEntity.vehicles,
        CrudEntity.maintenance,
        CrudEntity.routes,
        CrudEntity.zones,
      }.contains(entity);
    }

    if (role == 'dispatcher') {
      return entity == CrudEntity.trips && action != 'delete';
    }

    if (role == 'driver') {
      return entity == CrudEntity.trips && action == 'edit';
    }

    if (role == 'accounting_staff') {
      return {CrudEntity.invoices, CrudEntity.billing}.contains(entity) &&
          action != 'delete';
    }

    return false;
  }
}
