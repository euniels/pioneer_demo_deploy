import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum FleetCrudEntityType { vehicle, driver }

class FleetCrudPolicy {
  const FleetCrudPolicy({
    required this.entityType,
    required this.isManagedLocally,
    required this.isGeotabLinked,
    required this.isInactive,
    required this.scopeLabel,
    required this.scopeDetail,
    required this.scopeColor,
    required this.scopeIcon,
    required this.canEdit,
    required this.canDeactivate,
    required this.canReactivate,
    required this.canDelete,
    required this.canPushToGeotab,
    required this.editDisabledReason,
    required this.deactivateDisabledReason,
    required this.deleteDisabledReason,
    required this.pushDisabledReason,
  });

  factory FleetCrudPolicy.vehicle(Map<String, dynamic> vehicle) {
    final localId = _manualVehicleId(vehicle);
    final managed = vehicle['managedLocally'] == true || localId.isNotEmpty;
    final geotabLinked = _hasValue(vehicle['geotabId']);
    final inactive = _statusOf(vehicle) == 'inactive';
    final canPush =
        managed &&
        (vehicle['canPushToGeotab'] == true ||
            vehicle['hasLocalGeotabChanges'] == true ||
            _syncStatusOf(vehicle) == 'failed' ||
            _syncStatusOf(vehicle) == 'local_modified');

    final scope = _scope(
      managed: managed,
      geotabLinked: geotabLinked,
      entityType: FleetCrudEntityType.vehicle,
    );

    return FleetCrudPolicy(
      entityType: FleetCrudEntityType.vehicle,
      isManagedLocally: managed,
      isGeotabLinked: geotabLinked,
      isInactive: inactive,
      scopeLabel: scope.label,
      scopeDetail: scope.detail,
      scopeColor: scope.color,
      scopeIcon: scope.icon,
      canEdit: managed,
      canDeactivate: managed && !inactive,
      canReactivate: managed && inactive,
      canDelete: managed,
      canPushToGeotab: canPush,
      editDisabledReason:
          'GeoTab-synced vehicles must be linked as PioneerPath-managed records before local edits.',
      deactivateDisabledReason: inactive
          ? 'This vehicle is already inactive.'
          : 'Only PioneerPath-managed vehicles can be deactivated locally.',
      deleteDisabledReason:
          'Only PioneerPath-managed vehicles can be permanently deleted. Prefer Deactivate when records may have trip history.',
      pushDisabledReason: managed
          ? 'GeoTab is already up to date or no local GeoTab fields changed.'
          : 'Only PioneerPath-managed vehicles can be pushed to GeoTab.',
    );
  }

  factory FleetCrudPolicy.driver(Map<String, dynamic> driver) {
    final managed = (driver['source'] ?? '').toString().toLowerCase() == 'manual';
    final geotabLinked =
        _hasValue(driver['geotabId']) ||
        _hasValue(driver['geotabUserId']) ||
        _hasValue(driver['assignedVehicleGeotabId']);
    final inactive = _statusOf(driver) == 'inactive';
    final canPush =
        managed &&
        (driver['canPushToGeotab'] == true ||
            driver['hasLocalGeotabChanges'] == true ||
            _syncStatusOf(driver) == 'failed' ||
            _syncStatusOf(driver) == 'local_modified');

    final scope = _scope(
      managed: managed,
      geotabLinked: geotabLinked,
      entityType: FleetCrudEntityType.driver,
    );

    return FleetCrudPolicy(
      entityType: FleetCrudEntityType.driver,
      isManagedLocally: managed,
      isGeotabLinked: geotabLinked,
      isInactive: inactive,
      scopeLabel: scope.label,
      scopeDetail: scope.detail,
      scopeColor: scope.color,
      scopeIcon: scope.icon,
      canEdit: managed,
      canDeactivate: managed && !inactive,
      canReactivate: managed && inactive,
      canDelete: managed,
      canPushToGeotab: canPush,
      editDisabledReason:
          'GeoTab-synced drivers must be linked as PioneerPath-managed records before local edits.',
      deactivateDisabledReason: inactive
          ? 'This driver is already inactive.'
          : 'Only PioneerPath-managed drivers can be deactivated locally.',
      deleteDisabledReason:
          'Only PioneerPath-managed drivers can be permanently deleted. Prefer Deactivate to preserve operations history.',
      pushDisabledReason: managed
          ? 'GeoTab is already up to date or no local GeoTab fields changed.'
          : 'Only PioneerPath-managed drivers can be pushed to GeoTab.',
    );
  }

  final FleetCrudEntityType entityType;
  final bool isManagedLocally;
  final bool isGeotabLinked;
  final bool isInactive;
  final String scopeLabel;
  final String scopeDetail;
  final Color scopeColor;
  final IconData scopeIcon;
  final bool canEdit;
  final bool canDeactivate;
  final bool canReactivate;
  final bool canDelete;
  final bool canPushToGeotab;
  final String editDisabledReason;
  final String deactivateDisabledReason;
  final String deleteDisabledReason;
  final String pushDisabledReason;
}

class _FleetCrudScope {
  const _FleetCrudScope({
    required this.label,
    required this.detail,
    required this.color,
    required this.icon,
  });

  final String label;
  final String detail;
  final Color color;
  final IconData icon;
}

_FleetCrudScope _scope({
  required bool managed,
  required bool geotabLinked,
  required FleetCrudEntityType entityType,
}) {
  final noun = entityType == FleetCrudEntityType.vehicle ? 'vehicle' : 'driver';
  if (managed && geotabLinked) {
    return _FleetCrudScope(
      label: 'Managed + GeoTab linked',
      detail: 'Editable locally; GeoTab changes require approval.',
      color: AppTheme.primaryBlue,
      icon: Icons.sync_alt_rounded,
    );
  }
  if (managed) {
    return _FleetCrudScope(
      label: 'PioneerPath managed',
      detail: 'Editable local $noun record.',
      color: AppTheme.successGreen,
      icon: Icons.edit_note_rounded,
    );
  }
  if (geotabLinked) {
    return _FleetCrudScope(
      label: 'GeoTab synced',
      detail: 'Read-only imported GeoTab $noun.',
      color: AppTheme.neutralGray,
      icon: Icons.cloud_done_rounded,
    );
  }
  return _FleetCrudScope(
    label: 'Read-only record',
    detail: 'This $noun is not linked to a local managed record.',
    color: AppTheme.neutralGray,
    icon: Icons.lock_outline_rounded,
  );
}

String _manualVehicleId(Map<String, dynamic> vehicle) {
  final localId = vehicle['localId']?.toString().trim() ?? '';
  if (localId.isNotEmpty) {
    return localId;
  }
  return (vehicle['id']?.toString() ?? '')
      .replaceFirst('manual-vehicle-', '')
      .trim();
}

String _statusOf(Map<String, dynamic> entity) =>
    (entity['status'] ?? '').toString().trim().toLowerCase();

String _syncStatusOf(Map<String, dynamic> entity) =>
    (entity['syncStatus'] ?? '').toString().trim().toLowerCase();

bool _hasValue(dynamic value) => (value?.toString().trim() ?? '').isNotEmpty;
