import 'dart:async';

import 'package:flutter/material.dart';

import 'backend_api.dart';
import 'local_fleet_mirror_service.dart';
import 'notification_service.dart';
import '../theme/app_theme.dart';

final ValueNotifier<List<Map<String, dynamic>>> vehiclesNotifier =
    ValueNotifier<List<Map<String, dynamic>>>(_initialVehicles());

List<Map<String, dynamic>> _initialVehicles() => [];

void addVehicle(Map<String, dynamic> vehicle) {
  vehiclesNotifier.value = [...vehiclesNotifier.value, vehicle];
  _persistVehiclesMirror();
  final service = NotificationService.instance;
  service.addNotification(
    NotificationItem(
      id: service.nextId(),
      title: 'New Vehicle Added',
      message:
          '${vehicle['plate']} (${vehicle['truckType']}) has been registered to the fleet.',
      time: 'Just now',
      timestamp: DateTime.now(),
      category: NotificationCategory.system,
      isRead: false,
    ),
  );
}

void updateVehicle(String plate, Map<String, dynamic> updates) {
  vehiclesNotifier.value = vehiclesNotifier.value.map((vehicle) {
    if (vehicle['plate'] == plate) {
      return {...vehicle, ...updates};
    }
    return vehicle;
  }).toList();
  _persistVehiclesMirror();
}

Future<List<Map<String, dynamic>>> refreshVehiclesFromBackend() async {
  final backendVehicles = await BackendApiService.getVehicles();
  if (backendVehicles.isEmpty) {
    return vehiclesNotifier.value;
  }

  final currentVehicles = List<Map<String, dynamic>>.from(
    vehiclesNotifier.value,
  );
  final existingByPlate = {
    for (final vehicle in currentVehicles)
      _plateKey(vehicle['plate']?.toString() ?? ''): vehicle,
  };

  final synced = backendVehicles.map((vehicle) {
    final existing =
        existingByPlate[_plateKey(vehicle['plate']?.toString() ?? '')];
    return _mergeBackendVehicle(vehicle, existing);
  }).toList();

  final backendPlateKeys = synced
      .map((vehicle) => _plateKey(vehicle['plate']?.toString() ?? ''))
      .toSet();
  final localOnlyVehicles = currentVehicles.where((vehicle) {
    final plateKey = _plateKey(vehicle['plate']?.toString() ?? '');
    final hasGeotabId =
        vehicle['geotabId']?.toString().trim().isNotEmpty ?? false;
    return !backendPlateKeys.contains(plateKey) && !hasGeotabId;
  });

  final merged = [...synced, ...localOnlyVehicles];
  vehiclesNotifier.value = merged;
  _persistVehiclesMirror();
  return merged;
}

Future<Map<String, dynamic>> createVehicleInBackend(
  Map<String, dynamic> payload,
) async {
  final created = await BackendApiService.createManualVehicle(payload);
  final vehicle = _mergeBackendVehicle(created, null);
  final plate = _plateKey(vehicle['plate']?.toString() ?? '');
  vehiclesNotifier.value = [
    ...vehiclesNotifier.value.where(
      (item) => _plateKey(item['plate']?.toString() ?? '') != plate,
    ),
    vehicle,
  ];
  _persistVehiclesMirror();
  return vehicle;
}

Future<Map<String, dynamic>> updateVehicleInBackend(
  String vehicleId,
  Map<String, dynamic> payload,
) async {
  final updated = await BackendApiService.updateManualVehicle(
    vehicleId,
    payload,
  );
  final vehicle = _mergeBackendVehicle(updated, null);
  final plate = _plateKey(vehicle['plate']?.toString() ?? '');
  vehiclesNotifier.value = vehiclesNotifier.value.map((item) {
    final itemId = item['localId']?.toString() ?? item['id']?.toString() ?? '';
    final itemPlate = _plateKey(item['plate']?.toString() ?? '');
    if (itemId == vehicleId ||
        itemId == 'manual-vehicle-$vehicleId' ||
        itemPlate == plate) {
      return {...item, ...vehicle};
    }
    return item;
  }).toList();
  _persistVehiclesMirror();
  return vehicle;
}

Future<Map<String, dynamic>> deactivateVehicleInBackend(
  String vehicleId, {
  String reason = 'Deactivated from PioneerPath vehicles page.',
}) async {
  final updated = await BackendApiService.deactivateManualVehicle(
    vehicleId,
    reason: reason,
  );
  final vehicle = _mergeBackendVehicle(updated, null);
  final plate = _plateKey(vehicle['plate']?.toString() ?? '');
  vehiclesNotifier.value = vehiclesNotifier.value.map((item) {
    final itemId = item['localId']?.toString() ?? item['id']?.toString() ?? '';
    final itemPlate = _plateKey(item['plate']?.toString() ?? '');
    if (itemId == vehicleId ||
        itemId == 'manual-vehicle-$vehicleId' ||
        itemPlate == plate) {
      return {...item, ...vehicle};
    }
    return item;
  }).toList();
  _persistVehiclesMirror();
  return vehicle;
}

Future<void> deleteVehicleInBackend(Map<String, dynamic> vehicle) async {
  final id =
      vehicle['localId']?.toString() ??
      vehicle['id']?.toString().replaceFirst('manual-vehicle-', '') ??
      '';
  if (id.isEmpty || vehicle['managedLocally'] != true) {
    throw StateError('Only managed PioneerPath vehicles can be deleted.');
  }

  final previous = vehiclesNotifier.value
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
  vehiclesNotifier.value = vehiclesNotifier.value.where((item) {
    final itemId = item['localId']?.toString() ?? item['id']?.toString() ?? '';
    return itemId != id && itemId != 'manual-vehicle-$id';
  }).toList();
  _persistVehiclesMirror();

  try {
    await BackendApiService.deleteManualVehicle(id);
  } catch (_) {
    vehiclesNotifier.value = previous;
    _persistVehiclesMirror();
    rethrow;
  }
}

Future<Map<String, dynamic>> pushVehicleToGeotab(
  Map<String, dynamic> vehicle, {
  bool previewOnly = false,
}) async {
  final id =
      vehicle['localId']?.toString() ??
      vehicle['id']?.toString().replaceFirst('manual-vehicle-', '') ??
      '';
  if (id.isEmpty) {
    throw StateError(
      'Only managed PioneerPath vehicles can be pushed to GeoTab.',
    );
  }

  final updated = await BackendApiService.pushManualVehicleToGeotab(
    id,
    previewOnly: previewOnly,
  );
  if (previewOnly) {
    return updated;
  }
  final merged = _mergeBackendVehicle(updated, vehicle);
  final plate = _plateKey(merged['plate']?.toString() ?? '');
  vehiclesNotifier.value = vehiclesNotifier.value.map((item) {
    final itemId = item['localId']?.toString() ?? item['id']?.toString() ?? '';
    final itemPlate = _plateKey(item['plate']?.toString() ?? '');
    if (itemId == id || itemId == 'manual-vehicle-$id' || itemPlate == plate) {
      return {...item, ...merged};
    }
    return item;
  }).toList();
  _persistVehiclesMirror();
  return merged;
}

void refreshVehiclesFromBackendSilently() {
  refreshVehiclesFromBackend().catchError((_) {
    // Keep the current in-memory fleet when the backend is unavailable.
    return vehiclesNotifier.value;
  });
}

Future<List<Map<String, dynamic>>> refreshVehicleLocationsFromBackend() async {
  final livePayload = await BackendApiService.getFleetSummaryLive();
  return applyFleetLivePayload(livePayload);
}

List<Map<String, dynamic>> applyFleetLivePayload(
  Map<String, dynamic> livePayload,
) {
  final snapshots = ((livePayload['vehicles'] as List?) ?? const [])
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .toList();
  if (snapshots.isEmpty) {
    return vehiclesNotifier.value;
  }

  if (vehiclesNotifier.value.isEmpty) {
    vehiclesNotifier.value = snapshots
        .map((snapshot) => _mergeBackendVehicle(snapshot, null))
        .toList();
    return vehiclesNotifier.value;
  }

  final snapshotById = {
    for (final snapshot in snapshots)
      (snapshot['geotabId'] ?? '').toString(): snapshot,
  };

  vehiclesNotifier.value = vehiclesNotifier.value.map((vehicle) {
    final geotabId = (vehicle['geotabId'] ?? '').toString();
    final snapshot = snapshotById[geotabId];
    if (snapshot == null) {
      return vehicle;
    }

    final incomingUpdatedAt = _parseTimestamp(
      snapshot['lastGeotabAt'] ?? snapshot['lastUpdated'],
    );
    final currentUpdatedAt = _parseTimestamp(
      vehicle['lastGeotabAt'] ?? vehicle['lastUpdated'],
    );

    if (incomingUpdatedAt != null &&
        currentUpdatedAt != null &&
        incomingUpdatedAt.isBefore(currentUpdatedAt)) {
      return {
        ...vehicle,
        'syncState': snapshot['syncState'] ?? vehicle['syncState'] ?? 'live',
        'sourceAgeMs':
            _toInt(snapshot['sourceAgeMs']) ?? vehicle['sourceAgeMs'] ?? 0,
      };
    }

    final nextStatus = _normalizeStatus(
      snapshot['isDriving'] == true ? 'on trip' : vehicle['status']?.toString(),
    );

    return {
      ...vehicle,
      'latitude': _toDouble(snapshot['latitude']) ?? vehicle['latitude'] ?? 0.0,
      'longitude':
          _toDouble(snapshot['longitude']) ?? vehicle['longitude'] ?? 0.0,
      'speed': _toInt(snapshot['speed']) ?? vehicle['speed'] ?? 0,
      'bearing': _toInt(snapshot['bearing']) ?? vehicle['bearing'] ?? 0,
      'isDriving': snapshot['isDriving'] == true,
      'ignitionOn': snapshot['ignitionOn'] == true,
      'isCommunicating':
          snapshot['isCommunicating'] == true ||
          vehicle['isCommunicating'] == true,
      'status': nextStatus,
      'statusColor': _statusColorFor(nextStatus),
      'lastGeotabAt': snapshot['lastGeotabAt'] ?? vehicle['lastGeotabAt'],
      'sourceAgeMs': _toInt(snapshot['sourceAgeMs']) ?? vehicle['sourceAgeMs'],
      'syncState': snapshot['syncState'] ?? vehicle['syncState'] ?? 'live',
      'lastUpdated': snapshot['lastUpdated'] ?? vehicle['lastUpdated'],
      'currentZone': snapshot['currentZone'] ?? vehicle['currentZone'],
      'destinationZone':
          snapshot['destinationZone'] ?? vehicle['destinationZone'],
      'arrivalState': snapshot['arrivalState'] ?? vehicle['arrivalState'],
      'currentLocationLabel':
          snapshot['currentLocationLabel'] ?? vehicle['currentLocationLabel'],
      'assignedRoute': snapshot['routeName'] ?? vehicle['assignedRoute'],
      'routeStops': snapshot['routeStops'] ?? vehicle['routeStops'] ?? const [],
      'healthStatus': snapshot['healthStatus'] ?? vehicle['healthStatus'],
    };
  }).toList();

  return vehiclesNotifier.value;
}

Map<String, dynamic> _mergeBackendVehicle(
  Map<String, dynamic> backendVehicle,
  Map<String, dynamic>? existing,
) {
  final status = _normalizeStatus(
    backendVehicle['status']?.toString(),
    isDriving: backendVehicle['isDriving'] == true,
  );

  return {
    ...?existing,
    ...backendVehicle,
    'geotabId': backendVehicle['geotabId'] ?? existing?['geotabId'] ?? '',
    'name': backendVehicle['name'] ?? existing?['name'] ?? '',
    'plate': (backendVehicle['plate'] ?? existing?['plate'] ?? 'Unknown')
        .toString()
        .toUpperCase(),
    'truckType': _pickValue(
      backendVehicle['truckType'],
      existing?['truckType'],
      fallback: 'Truck',
    ),
    'deliveryFit': _pickValue(
      backendVehicle['deliveryFit'],
      existing?['deliveryFit'],
      fallback: 'General multi-stop delivery',
    ),
    'fuelCapacity': _pickValue(
      backendVehicle['fuelCapacity'],
      existing?['fuelCapacity'],
      fallback: 'N/A',
    ),
    'year': _pickValue(
      backendVehicle['year'],
      existing?['year'],
      fallback: 'N/A',
    ),
    'status': status,
    'statusColor': _statusColorFor(status),
    'mileage': _pickValue(
      backendVehicle['mileage'],
      existing?['mileage'],
      fallback: '0',
    ),
    'numTrips':
        _toInt(backendVehicle['numTrips'] ?? existing?['numTrips']) ?? 0,
    'totalRevenue':
        _toInt(backendVehicle['totalRevenue'] ?? existing?['totalRevenue']) ??
        0,
    'driver': _pickValue(
      backendVehicle['driver'],
      existing?['driver'],
      fallback: 'Unassigned',
    ),
    'latitude': _toDouble(backendVehicle['latitude']) ?? 0.0,
    'longitude': _toDouble(backendVehicle['longitude']) ?? 0.0,
    'speed': _toInt(backendVehicle['speed']) ?? 0,
    'bearing': _toInt(backendVehicle['bearing']) ?? 0,
    'isDriving': backendVehicle['isDriving'] == true,
    'ignitionOn': backendVehicle['ignitionOn'] == true,
    'isCommunicating': backendVehicle['isCommunicating'] == true,
    'lastGeotabAt': backendVehicle['lastGeotabAt'] ?? existing?['lastGeotabAt'],
    'sourceAgeMs':
        _toInt(backendVehicle['sourceAgeMs'] ?? existing?['sourceAgeMs']) ?? 0,
    'syncState':
        backendVehicle['syncState'] ?? existing?['syncState'] ?? 'live',
    'lastUpdated': backendVehicle['lastUpdated'] ?? existing?['lastUpdated'],
    'comment': backendVehicle['comment'] ?? existing?['comment'] ?? '',
    'serialNumber':
        backendVehicle['serialNumber'] ?? existing?['serialNumber'] ?? '',
    'vin': backendVehicle['vin'] ?? existing?['vin'] ?? '',
    'deviceType': backendVehicle['deviceType'] ?? existing?['deviceType'] ?? '',
    'fuelLevelRatio':
        _toDouble(
          backendVehicle['fuelLevelRatio'] ?? existing?['fuelLevelRatio'],
        ) ??
        0.0,
    'fuelLevelSupported':
        backendVehicle['fuelLevelSupported'] == true ||
        existing?['fuelLevelSupported'] == true,
    'engineHours':
        _toDouble(backendVehicle['engineHours'] ?? existing?['engineHours']) ??
        0.0,
    'odometerKm':
        _toDouble(backendVehicle['odometerKm'] ?? existing?['odometerKm']) ??
        0.0,
    'fuelEconomyKmPerLiter':
        _toDouble(
          backendVehicle['fuelEconomyKmPerLiter'] ??
              existing?['fuelEconomyKmPerLiter'],
        ) ??
        0.0,
    'assignedRoute':
        backendVehicle['assignedRoute'] ?? existing?['assignedRoute'],
    'originZone': backendVehicle['originZone'] ?? existing?['originZone'],
    'currentZone': backendVehicle['currentZone'] ?? existing?['currentZone'],
    'destinationZone':
        backendVehicle['destinationZone'] ?? existing?['destinationZone'],
    'arrivalState':
        backendVehicle['arrivalState'] ?? existing?['arrivalState'] ?? 'idle',
    'currentLocationLabel':
        backendVehicle['currentLocationLabel'] ??
        existing?['currentLocationLabel'],
    'healthStatus':
        backendVehicle['healthStatus'] ??
        existing?['healthStatus'] ??
        'healthy',
    'healthScore':
        _toInt(backendVehicle['healthScore'] ?? existing?['healthScore']) ??
        100,
    'healthAlerts': _toStringDynamicMap(
      backendVehicle['healthAlerts'] ?? existing?['healthAlerts'],
    ),
    'assetTags': _toStringList(
      backendVehicle['assetTags'] ?? existing?['assetTags'],
    ),
    'routeStops': _toNestedMapList(
      backendVehicle['routeStops'] ?? existing?['routeStops'],
    ),
    'recentFaults': _toNestedMapList(
      backendVehicle['recentFaults'] ?? existing?['recentFaults'],
    ),
    'recentExceptions': _toNestedMapList(
      backendVehicle['recentExceptions'] ?? existing?['recentExceptions'],
    ),
    'lastInspection':
        backendVehicle['lastInspection'] ??
        existing?['lastInspection'] ??
        'N/A',
    'nextMaintenance':
        backendVehicle['nextMaintenance'] ??
        existing?['nextMaintenance'] ??
        'N/A',
    'documents':
        backendVehicle['documents'] ?? existing?['documents'] ?? const [],
    'syncStatus':
        backendVehicle['syncStatus'] ?? existing?['syncStatus'] ?? 'not_staged',
    'syncLabel':
        backendVehicle['syncLabel'] ?? existing?['syncLabel'] ?? 'Not Synced',
    'syncError': backendVehicle['syncError'] ?? existing?['syncError'],
    'pendingWriteJobId':
        backendVehicle['pendingWriteJobId'] ?? existing?['pendingWriteJobId'],
    'hasLocalGeotabChanges': backendVehicle.containsKey('hasLocalGeotabChanges')
        ? backendVehicle['hasLocalGeotabChanges'] == true
        : existing?['hasLocalGeotabChanges'] == true,
    'canPushToGeotab': backendVehicle.containsKey('canPushToGeotab')
        ? backendVehicle['canPushToGeotab'] == true
        : existing?['canPushToGeotab'] == true,
  };
}

String _plateKey(String plate) => plate.trim().toLowerCase();

String _normalizeStatus(String? rawStatus, {bool isDriving = false}) {
  if (isDriving) {
    return 'on trip';
  }

  switch ((rawStatus ?? '').trim().toLowerCase()) {
    case 'on trip':
    case 'ontrip':
    case 'in transit':
      return 'on trip';
    case 'maintenance':
    case 'under maintenance':
    case 'under_maintenance':
      return 'maintenance';
    case 'inactive':
    case 'deactivated':
    case 'retired':
      return 'inactive';
    default:
      return 'available';
  }
}

Color _statusColorFor(String status) {
  switch (status) {
    case 'on trip':
      return AppTheme.colorFF4B7BE5;
    case 'maintenance':
      return AppTheme.colorFFF39C12;
    case 'inactive':
      return AppTheme.gray500;
    default:
      return AppTheme.colorFF27AE60;
  }
}

String _pickValue(
  dynamic preferred,
  dynamic fallbackValue, {
  required String fallback,
}) {
  final first = preferred?.toString().trim();
  if (first != null && first.isNotEmpty && first != 'N/A') {
    return first;
  }

  final second = fallbackValue?.toString().trim();
  if (second != null && second.isNotEmpty) {
    return second;
  }

  return fallback;
}

double? _toDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }

  if (value is String && value.trim().isNotEmpty) {
    return double.tryParse(value.trim());
  }

  return null;
}

int? _toInt(dynamic value) {
  if (value is int) {
    return value;
  }

  if (value is num) {
    return value.toInt();
  }

  if (value is String && value.trim().isNotEmpty) {
    return int.tryParse(value.trim());
  }

  return null;
}

DateTime? _parseTimestamp(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) {
    return null;
  }

  return DateTime.tryParse(raw)?.toUtc();
}

List<String> _toStringList(dynamic value) {
  if (value is! List) {
    return const [];
  }

  return value
      .map((item) => item?.toString().trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toList();
}

Map<String, dynamic> _toStringDynamicMap(dynamic value) {
  if (value is! Map) {
    return const {};
  }

  return value.map((key, val) => MapEntry(key.toString(), val));
}

List<Map<String, dynamic>> _toNestedMapList(dynamic value) {
  if (value is! List) {
    return const [];
  }

  return value
      .whereType<Map>()
      .map((item) => item.map((key, val) => MapEntry(key.toString(), val)))
      .cast<Map<String, dynamic>>()
      .toList();
}

void _persistVehiclesMirror() {
  unawaited(
    LocalFleetMirrorService.replaceVehicles(
      vehiclesNotifier.value,
    ).catchError((_) {}),
  );
}
