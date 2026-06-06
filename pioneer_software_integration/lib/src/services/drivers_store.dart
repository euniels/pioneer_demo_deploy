// lib/src/services/drivers_store.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'backend_api.dart';
import 'local_fleet_mirror_service.dart';
import 'notification_service.dart';
import '../theme/app_theme.dart';

final ValueNotifier<List<Map<String, dynamic>>> driversNotifier =
    ValueNotifier<List<Map<String, dynamic>>>(_initialDrivers());
final Map<String, Future<Map<String, dynamic>>> _driverCreateRequests = {};

List<Map<String, dynamic>> _initialDrivers() => [];

void updateDriverStatus(String name, String status) {
  final Color statusColor;
  switch (status.toLowerCase()) {
    case 'available':
      statusColor = AppTheme.colorFF27AE60;
      break;
    case 'on trip':
      statusColor = AppTheme.colorFF4B7BE5;
      break;
    default:
      statusColor = AppTheme.colorFF27AE60;
  }

  driversNotifier.value = driversNotifier.value.map((driver) {
    if (driver['name'] == name) {
      return {...driver, 'status': status, 'statusColor': statusColor};
    }
    return driver;
  }).toList();
  _persistDriversMirror();
}

void updateDriverTripStats(String driverName, int tripAmount) {
  driversNotifier.value = driversNotifier.value.map((driver) {
    if (driver['name'] == driverName) {
      final currentTrips = (driver['trips'] as int?) ?? 0;
      final revenueStr = (driver['revenue'] as String? ?? 'PHP 0.00')
          .replaceAll('PHP', '')
          .replaceAll(',', '')
          .trim();
      final currentRevenue = double.tryParse(revenueStr) ?? 0;
      final newRevenue = currentRevenue + tripAmount;

      return {
        ...driver,
        'trips': currentTrips + 1,
        'revenue': 'PHP ${newRevenue.toStringAsFixed(2)}',
      };
    }
    return driver;
  }).toList();
  _persistDriversMirror();
}

void addDriver(Map<String, dynamic> driver) {
  driversNotifier.value = [...driversNotifier.value, driver];
  _persistDriversMirror();
  final svc = NotificationService.instance;
  svc.addNotification(
    NotificationItem(
      id: svc.nextId(),
      title: 'New Driver Added',
      message:
          '${driver['name']} has been added to the fleet. License: ${driver['license']}.',
      time: 'Just now',
      timestamp: DateTime.now(),
      category: NotificationCategory.driver,
      isRead: false,
    ),
  );
}

Future<void> refreshDriversFromBackend({bool forceRefresh = false}) async {
  try {
    final analytics = await BackendApiService.getFleetSummaryAnalytics(
      forceRefresh: forceRefresh,
    );
    final operations = analytics['operations'];
    final drivers = operations is Map ? operations['drivers'] : null;
    if (drivers is List && drivers.isNotEmpty) {
      driversNotifier.value = drivers
          .whereType<Map>()
          .map((driver) => _normalizedDriver(Map<String, dynamic>.from(driver)))
          .toList();
      _persistDriversMirror();
      return;
    }

    final manualDrivers = await BackendApiService.getManualDrivers(
      forceRefresh: forceRefresh,
    );
    driversNotifier.value = manualDrivers
        .map((driver) => _normalizedDriver(Map<String, dynamic>.from(driver)))
        .toList();
    _persistDriversMirror();
  } catch (_) {}
}

Future<Map<String, dynamic>> addDriverToBackend(
  Map<String, dynamic> driver,
) async {
  final payload = {
    'name': driver['name'],
    'license': driver['license'],
    'phone': driver['phone'],
    'email': driver['email'],
    'assignedVehiclePlate': driver['assignedVehiclePlate'],
    'status': driver['status'] ?? 'available',
    'meta': {
      ...((driver['meta'] is Map)
          ? Map<String, dynamic>.from(driver['meta'] as Map)
          : const <String, dynamic>{}),
      'score': driver['score'] ?? 92,
      'delays': driver['delays'] ?? 0,
      'trips': driver['trips'] ?? 0,
    },
  };
  final requestKey = jsonEncode(payload);
  final inFlight = _driverCreateRequests[requestKey];
  if (inFlight != null) {
    return inFlight;
  }

  final request = _createDriverAndUpdateStore(driver, payload);
  _driverCreateRequests[requestKey] = request;
  try {
    return await request;
  } finally {
    if (identical(_driverCreateRequests[requestKey], request)) {
      _driverCreateRequests.remove(requestKey);
    }
  }
}

Future<Map<String, dynamic>> _createDriverAndUpdateStore(
  Map<String, dynamic> driver,
  Map<String, dynamic> payload,
) async {
  final response = await BackendApiService.createManualDriver(payload);
  if (response['queued'] == true) {
    throw const BackendApiException(
      'The driver could not be confirmed by the server yet. Check your connection and try again.',
    );
  }
  final created = _normalizedDriver({
    ...driver,
    ...Map<String, dynamic>.from(response),
  });
  driversNotifier.value = [...driversNotifier.value, created];
  _persistDriversMirror();
  final svc = NotificationService.instance;
  svc.addNotification(
    NotificationItem(
      id: svc.nextId(),
      title: 'New Driver Added',
      message:
          '${created['name']} has been added to the fleet. License: ${created['license']}.',
      time: 'Just now',
      timestamp: DateTime.now(),
      category: NotificationCategory.driver,
      isRead: false,
    ),
  );
  return created;
}

Future<void> deactivateDriverInBackend(Map<String, dynamic> driver) async {
  final id = driver['id']?.toString() ?? '';
  if (id.isEmpty || driver['source'] != 'manual') {
    updateDriverStatus(driver['name']?.toString() ?? '', 'inactive');
    return;
  }

  final previous = driversNotifier.value
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
  final deactivatedAt = DateTime.now().toIso8601String();
  final optimistic = _normalizedDriver({
    ...driver,
    'status': 'inactive',
    'meta': {
      ...((driver['meta'] is Map)
          ? Map<String, dynamic>.from(driver['meta'] as Map)
          : const <String, dynamic>{}),
      'deactivatedAt': deactivatedAt,
      'syncStatus': 'pending_deactivation',
    },
  });

  driversNotifier.value = driversNotifier.value
      .map((item) => item['id']?.toString() == id ? optimistic : item)
      .toList();
  _persistDriversMirror();

  try {
    final response = await BackendApiService.deactivateManualDriver(
      id,
      reason: 'Deactivated from the PioneerPath Drivers page.',
    );
    final updated = _normalizedDriver({
      ...optimistic,
      ...Map<String, dynamic>.from(response),
    });
    driversNotifier.value = driversNotifier.value
        .map((item) => item['id']?.toString() == id ? updated : item)
        .toList();
    _persistDriversMirror();
  } catch (_) {
    driversNotifier.value = previous;
    _persistDriversMirror();
    rethrow;
  }
}

Future<void> reactivateDriverInBackend(Map<String, dynamic> driver) async {
  final id = driver['id']?.toString() ?? '';
  final previous = driversNotifier.value
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
  final optimistic = _normalizedDriver({...driver, 'status': 'available'});

  driversNotifier.value = driversNotifier.value.map((item) {
    final matches = id.isNotEmpty
        ? item['id']?.toString() == id
        : item['name'] == driver['name'];
    return matches ? optimistic : item;
  }).toList();
  _persistDriversMirror();

  if (id.isEmpty || driver['source'] != 'manual') {
    return;
  }

  try {
    final response = await BackendApiService.updateManualDriver(id, {
      'status': 'available',
    });
    if (response['queued'] == true) {
      throw const BackendApiException(
        'The reactivation could not be confirmed by the server yet.',
      );
    }
    final updated = _normalizedDriver({
      ...optimistic,
      ...Map<String, dynamic>.from(response),
    });
    driversNotifier.value = driversNotifier.value
        .map((item) => item['id']?.toString() == id ? updated : item)
        .toList();
    _persistDriversMirror();
  } catch (_) {
    driversNotifier.value = previous;
    _persistDriversMirror();
    rethrow;
  }
}

Future<void> deleteDriverInBackend(Map<String, dynamic> driver) async {
  final id = driver['id']?.toString() ?? '';
  if (id.isEmpty || driver['source'] != 'manual') {
    throw const BackendApiException(
      'Only locally managed drivers can be deleted.',
    );
  }

  final previous = driversNotifier.value
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
  driversNotifier.value = driversNotifier.value
      .where((item) => item['id']?.toString() != id)
      .toList();
  _persistDriversMirror();

  try {
    await BackendApiService.deleteManualDriver(id);
  } catch (_) {
    driversNotifier.value = previous;
    _persistDriversMirror();
    rethrow;
  }
}

Future<Map<String, dynamic>> updateDriverInBackend(
  Map<String, dynamic> driver,
) async {
  final id = driver['id']?.toString() ?? '';
  if (id.isEmpty || driver['source'] != 'manual') {
    return _normalizedDriver(driver);
  }

  final response = await BackendApiService.updateManualDriver(id, driver);
  if (response['queued'] == true) {
    throw const BackendApiException(
      'The driver update could not be confirmed by the server yet. Check your connection and try again.',
    );
  }
  final updated = _normalizedDriver({
    ...driver,
    ...Map<String, dynamic>.from(response),
  });
  driversNotifier.value = driversNotifier.value
      .map((item) => item['id']?.toString() == id ? updated : item)
      .toList();
  _persistDriversMirror();
  return updated;
}

Future<Map<String, dynamic>> pushDriverToGeotab(
  Map<String, dynamic> driver, {
  bool previewOnly = false,
}) async {
  final id = driver['id']?.toString() ?? '';
  if (id.isEmpty || driver['source'] != 'manual') {
    throw StateError('Only manual driver records can be pushed to GeoTab.');
  }

  final response = await BackendApiService.pushManualDriverToGeotab(
    id,
    previewOnly: previewOnly,
  );
  if (previewOnly) {
    return response;
  }
  final updated = _normalizedDriver({
    ...driver,
    ...Map<String, dynamic>.from(response),
  });
  driversNotifier.value = driversNotifier.value
      .map((item) => item['id']?.toString() == id ? updated : item)
      .toList();
  _persistDriversMirror();
  return updated;
}

Future<Map<String, dynamic>> anonymizeDriverInBackend(
  Map<String, dynamic> driver, {
  required String reason,
}) async {
  final id = driver['id']?.toString() ?? '';
  if (id.isEmpty || driver['source'] != 'manual') {
    throw StateError('Only manual driver records can be anonymized.');
  }

  final response = await BackendApiService.anonymizeManualDriver(
    id,
    reason: reason,
  );
  final updated = _normalizedDriver({
    ...driver,
    ...Map<String, dynamic>.from(response),
  });
  driversNotifier.value = driversNotifier.value
      .map((item) => item['id']?.toString() == id ? updated : item)
      .toList();
  _persistDriversMirror();
  return updated;
}

Map<String, dynamic> _normalizedDriver(Map<String, dynamic> driver) {
  final status = driver['status']?.toString().trim().toLowerCase() ?? '';
  final sanitized = Map<String, dynamic>.from(driver)
    ..remove('baseSalary')
    ..remove('perTripBonus')
    ..remove('base_salary')
    ..remove('per_trip_bonus')
    ..remove('salary');

  return {
    ...sanitized,
    'statusColor': driver['statusColor'] is Color
        ? driver['statusColor']
        : _statusColorFor(status),
  };
}

Color _statusColorFor(String status) {
  switch (status) {
    case 'on trip':
    case 'dispatched':
    case 'in transit':
      return AppTheme.colorFF4B7BE5;
    case 'maintenance':
      return AppTheme.colorFFF39C12;
    case 'available':
      return AppTheme.colorFF27AE60;
    default:
      return AppTheme.materialGrey;
  }
}

String? normalizeMoneyLikeValueForDriverWritePayload(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty || raw.toLowerCase() == 'n/a') {
    return null;
  }

  final cleaned = raw
      .replaceAll('PHP', '')
      .replaceAll('₱', '')
      .replaceAll(',', '')
      .trim();
  return cleaned.isEmpty ? null : cleaned;
}

void _persistDriversMirror() {
  unawaited(
    LocalFleetMirrorService.replaceDrivers(
      driversNotifier.value,
    ).catchError((_) {}),
  );
}
