import 'package:flutter/material.dart';

import 'backend_api.dart';
import 'auth.dart';
import 'billing_store.dart';
import 'drivers_store.dart';
import 'local_fleet_mirror_service.dart';
import 'maintenance_store.dart';
import 'notification_service.dart';
import 'trips_store.dart';
import 'vehicles_store.dart';
import '../theme/app_theme.dart';

Future<Map<String, dynamic>>? _fleetRefreshFuture;
Future<void>? _fleetBootstrapFuture;
Future<void>? _operationalWarmFuture;

Future<void> warmFleetStateFromCache() async {
  final localMirror = await LocalFleetMirrorService.loadState();
  if (localMirror.hasStableFleetData) {
    _applyFleetSummaryData({
      'vehicles': localMirror.vehicles,
      'drivers': localMirror.drivers,
      'trips': localMirror.trips,
      'notifications': localMirror.notifications,
    });
  }

  final cachedSummary = BackendApiService.peekCachedDataMap('/fleet/summary');
  if (cachedSummary != null &&
      cachedSummary.isNotEmpty &&
      !_hasReadableFleetState()) {
    _applyFleetSummaryData(cachedSummary);
  }

  final cachedLive =
      BackendApiService.peekCachedDataMap('/fleet/summary/live') ??
      BackendApiService.peekCachedDataMap('/fleet/live');
  if (cachedLive != null && cachedLive.isNotEmpty) {
    applyFleetLivePayload(cachedLive);
  }
}

bool _hasReadableFleetState() {
  return vehiclesNotifier.value.isNotEmpty ||
      driversNotifier.value.isNotEmpty ||
      tripsNotifier.value.isNotEmpty ||
      NotificationService.instance.notifications.value.isNotEmpty;
}

Future<void> refreshFleetBootstrap({bool forceRefresh = false}) {
  if (!forceRefresh && _fleetBootstrapFuture != null) {
    return _fleetBootstrapFuture!;
  }

  final future = _primeVehiclesFromLive(forceRefresh: forceRefresh)
      .whenComplete(() {
        _fleetBootstrapFuture = null;
      });

  _fleetBootstrapFuture = future;
  return future;
}

Future<void> warmOperationalCaches({bool forceRefresh = false}) {
  if (!forceRefresh && _operationalWarmFuture != null) {
    return _operationalWarmFuture!;
  }

  final future = _warmOperationalCachesSequential(forceRefresh: forceRefresh)
      .whenComplete(() {
        _operationalWarmFuture = null;
      });

  _operationalWarmFuture = future;
  return future;
}

Future<void> _warmOperationalCachesSequential({
  bool forceRefresh = false,
}) async {
  final role = AuthService.currentManagedRole;
  final fullOperations = const {
    'super_administrator',
    'system_administrator',
    'fleet_manager',
  }.contains(role);
  final requests = <Future<dynamic> Function()>[];

  if (fullOperations || role == 'dispatcher') {
    requests.addAll([
      () => BackendApiService.getFleetSummaryAnalytics(
        forceRefresh: forceRefresh,
      ),
      () => BackendApiService.getFleetSummaryMaintenance(
        forceRefresh: forceRefresh,
      ),
    ]);
  }

  if (fullOperations) {
    requests.addAll([
      () => BackendApiService.getFleetTelemetry(forceRefresh: forceRefresh),
      () => BackendApiService.getFleetTemperature(forceRefresh: forceRefresh),
      () => BackendApiService.getFleetFuel(forceRefresh: forceRefresh),
      () => BackendApiService.getFleetMaintenance(forceRefresh: forceRefresh),
    ]);
  }

  if (fullOperations || role == 'accounting_staff') {
    requests.addAll([
      () => BackendApiService.getBillingInvoices(forceRefresh: forceRefresh),
      () =>
          BackendApiService.getStatementOfAccounts(forceRefresh: forceRefresh),
    ]);
  }

  for (final request in requests) {
    await _warmOperationalRequest(request);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
}

Future<Map<String, dynamic>> refreshFleetSnapshot({bool forceRefresh = false}) {
  if (!forceRefresh && _fleetRefreshFuture != null) {
    return _fleetRefreshFuture!;
  }

  final future = _loadFleetSummary(forceRefresh: forceRefresh)
      .then((summary) {
        _applyFleetSummaryData(summary);
        return summary;
      })
      .whenComplete(() {
        _fleetRefreshFuture = null;
      });

  _fleetRefreshFuture = future;
  return future;
}

Future<void> _primeVehiclesFromLive({bool forceRefresh = false}) async {
  Object? lastError;

  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final livePayload = await BackendApiService.getFleetSummaryLive(
        forceRefresh: forceRefresh || attempt > 0,
      );
      final merged = applyFleetLivePayload(livePayload);
      if (_hasFleetVehicles(merged)) {
        return;
      }
    } catch (error) {
      lastError = error;
    }

    if (attempt < 2) {
      await Future<void>.delayed(Duration(milliseconds: 220 * (attempt + 1)));
    }
  }

  try {
    final summary = await _loadFleetSummary(forceRefresh: forceRefresh);
    _applyFleetSummaryData(summary);
    if (vehiclesNotifier.value.isNotEmpty) {
      try {
        await refreshVehicleLocationsFromBackend();
      } catch (_) {}
      return;
    }
  } catch (error) {
    lastError = error;
  }

  try {
    await refreshVehiclesFromBackend();
    if (vehiclesNotifier.value.isNotEmpty) {
      try {
        await refreshVehicleLocationsFromBackend();
      } catch (_) {}
      return;
    }
  } catch (error) {
    lastError = error;
  }

  if (lastError != null && vehiclesNotifier.value.isEmpty) {
    if (lastError is Error) {
      throw lastError;
    }
    throw lastError;
  }
}

Future<Map<String, dynamic>> _loadFleetSummary({
  bool forceRefresh = false,
}) async {
  try {
    return await BackendApiService.getFleetSummary(forceRefresh: forceRefresh);
  } catch (_) {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return BackendApiService.getFleetSummary(forceRefresh: true);
  }
}

Future<List<NotificationItem>> refreshNotificationsFromBackend({
  bool forceRefresh = false,
}) async {
  final current = NotificationService.instance.notifications.value;
  final raw = await BackendApiService.getFleetNotifications(
    forceRefresh: forceRefresh,
  );
  var notifications = _mapNotifications(raw);
  if (notifications.isEmpty) {
    final mirrored = await LocalFleetMirrorService.loadCollection(
      LocalFleetMirrorService.notificationsCollection,
    );
    notifications = _mapNotifications(mirrored);
  }
  if (notifications.isEmpty && current.isNotEmpty) {
    return current;
  }
  NotificationService.instance.replaceNotifications(notifications);
  return notifications;
}

void refreshFleetSnapshotSilently({bool forceRefresh = false}) {
  refreshFleetSnapshot(forceRefresh: forceRefresh).catchError((_) {
    // Keep the current in-memory data when the backend is unavailable.
    return <String, dynamic>{};
  });
}

void refreshFleetBootstrapSilently({bool forceRefresh = false}) {
  refreshFleetBootstrap(forceRefresh: forceRefresh).catchError((_) {
    // Keep the current in-memory data when the lightweight live bootstrap fails.
  });
}

void warmOperationalCachesSilently({bool forceRefresh = false}) {
  warmOperationalCaches(forceRefresh: forceRefresh).catchError((_) {
    // Keep page-level loads cache-first even if this startup warmup misses.
  });
}

void _applyFleetSummaryData(Map<String, dynamic> summary) {
  vehiclesNotifier.value = _retainLastGoodList(
    current: vehiclesNotifier.value,
    next: _mapVehicles(summary['vehicles']),
  );
  driversNotifier.value = _retainLastGoodList(
    current: driversNotifier.value,
    next: _mapDrivers(summary['drivers']),
  );
  tripsNotifier.value = _retainLastGoodList(
    current: tripsNotifier.value,
    next: _mapTrips(summary['trips']),
  );
  maintenanceNotifier.value = _retainLastGoodList(
    current: maintenanceNotifier.value,
    next: _mapMaintenance(summary['maintenance']),
  );
  billingsNotifier.value = _retainLastGoodList(
    current: billingsNotifier.value,
    next: _mapBillings(summary['billings']),
  );

  final notifications = _retainLastGoodNotifications(
    current: NotificationService.instance.notifications.value,
    next: _mapNotifications(summary['notifications']),
  );
  NotificationService.instance.replaceNotifications(notifications);
}

bool _hasFleetVehicles(List<Map<String, dynamic>> vehicles) {
  if (vehicles.isEmpty) {
    return false;
  }

  return vehicles.any((vehicle) {
    final latitude = (vehicle['latitude'] as num?)?.toDouble() ?? 0.0;
    final longitude = (vehicle['longitude'] as num?)?.toDouble() ?? 0.0;
    return latitude != 0.0 || longitude != 0.0;
  });
}

Future<void> _warmOperationalRequest(Future<dynamic> Function() request) async {
  try {
    await request();
  } catch (_) {
    // Individual operational datasets should not break the warmup lane.
  }
}

List<Map<String, dynamic>> _retainLastGoodList({
  required List<Map<String, dynamic>> current,
  required List<Map<String, dynamic>> next,
}) {
  if (next.isEmpty && current.isNotEmpty) {
    return current;
  }
  return next;
}

List<NotificationItem> _retainLastGoodNotifications({
  required List<NotificationItem> current,
  required List<NotificationItem> next,
}) {
  if (next.isEmpty && current.isNotEmpty) {
    return current;
  }
  return next;
}

List<Map<String, dynamic>> _mapVehicles(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw.whereType<Map>().map((item) {
    final map = _stringMap(item);
    final status = _normalizeVehicleStatus(map['status']?.toString());

    return {
      ...map,
      'plate': (map['plate'] ?? 'UNKNOWN').toString().toUpperCase(),
      'status': status,
      'statusColor': _vehicleStatusColor(status),
      'truckType': _cleanString(map['truckType'], fallback: 'Truck'),
      'deliveryFit': _cleanString(
        map['deliveryFit'],
        fallback: 'General multi-stop delivery',
      ),
      'fuelCapacity': _cleanString(map['fuelCapacity'], fallback: 'N/A'),
      'year': _cleanString(map['year'], fallback: 'N/A'),
      'mileage': _cleanString(map['mileage'], fallback: '0'),
      'numTrips': _toInt(map['numTrips']),
      'totalRevenue': _toInt(map['totalRevenue']),
      'speed': _toInt(map['speed']),
      'bearing': _toInt(map['bearing']),
      'latitude': _toDouble(map['latitude']),
      'longitude': _toDouble(map['longitude']),
      'fuelLevelRatio': _toDouble(map['fuelLevelRatio']),
      'fuelLevelSupported': map['fuelLevelSupported'] == true,
      'fuelUsedLiters7d': _toDouble(map['fuelUsedLiters7d']),
      'idlingFuelUsedLiters7d': _toDouble(map['idlingFuelUsedLiters7d']),
      'energyUsedKwh7d': _toDouble(map['energyUsedKwh7d']),
      'engineHours': _toDouble(map['engineHours']),
      'odometerKm': _toDouble(map['odometerKm']),
      'fuelEconomyKmPerLiter': _toDouble(map['fuelEconomyKmPerLiter']),
      'isDriving': map['isDriving'] == true,
      'isCommunicating': map['isCommunicating'] == true,
      'assetTags': _stringList(map['assetTags']),
      'assignedRoute': _nullableString(map['assignedRoute']),
      'originZone': _nullableString(map['originZone']),
      'currentZone': _nullableString(map['currentZone']),
      'destinationZone': _nullableString(map['destinationZone']),
      'arrivalState': _cleanString(map['arrivalState'], fallback: 'idle'),
      'currentLocationLabel': _nullableString(map['currentLocationLabel']),
      'healthStatus': _cleanString(map['healthStatus'], fallback: 'healthy'),
      'healthScore': _toInt(map['healthScore']),
      'healthAlerts': _stringMap(map['healthAlerts']),
      'routeStops': _mapNestedList(map['routeStops']),
      'recentFaults': _mapNestedList(map['recentFaults']),
      'recentExceptions': _mapNestedList(map['recentExceptions']),
      'documents': _mapNestedList(map['documents']),
    };
  }).toList();
}

List<Map<String, dynamic>> _mapDrivers(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw.whereType<Map>().map((item) {
    final map = _stringMap(item);
    final status = _normalizeDriverStatus(map['status']?.toString());

    return {
      ...map,
      'name': _cleanString(map['name'], fallback: 'Unassigned'),
      'status': status,
      'statusColor': _driverStatusColor(status),
      'trips': _toInt(map['trips']),
      'score': _toInt(map['score']),
      'delays': _toInt(map['delays']),
      'license': _cleanString(map['license'], fallback: 'N/A'),
      'licenseExpiry': _cleanString(map['licenseExpiry'], fallback: 'N/A'),
      'phone': _cleanString(map['phone'], fallback: 'N/A'),
      'email': _cleanString(map['email'], fallback: 'N/A'),
      'joinDate': _cleanString(map['joinDate'], fallback: 'N/A'),
      'baseSalary': _cleanString(map['baseSalary'], fallback: 'N/A'),
      'perTripBonus': _cleanString(map['perTripBonus'], fallback: 'N/A'),
      'revenue': _cleanString(map['revenue'], fallback: 'PHP 0.00'),
    };
  }).toList();
}

List<Map<String, dynamic>> _mapTrips(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw.whereType<Map>().map((item) {
    final map = _stringMap(item);
    final status = _normalizeTripStatus(map['status']?.toString());

    return {
      ...map,
      'tripId': _cleanString(map['tripId'], fallback: 'TRP-SYNCED'),
      'status': status,
      'statusColor': _tripStatusColor(status),
      'customer': _cleanString(map['customer'], fallback: 'Geotab Trip'),
      'phone': _cleanString(map['phone'], fallback: 'N/A'),
      'origin': _cleanString(map['origin'], fallback: 'Trip start'),
      'destination': _cleanString(map['destination'], fallback: 'Trip stop'),
      'vehicle': _cleanString(map['vehicle'], fallback: 'N/A'),
      'driver': _cleanString(map['driver'], fallback: 'Unassigned'),
      'amount': _cleanString(map['amount'], fallback: 'PHP 0.00'),
      'delay': _cleanString(map['delay'], fallback: ''),
      'hasDelay': map['hasDelay'] == true,
      'distanceKm': _toDouble(map['distanceKm']),
      'averageSpeed': _toDouble(map['averageSpeed']),
      'maximumSpeed': _toDouble(map['maximumSpeed']),
      'drivingMinutes': _toInt(map['drivingMinutes']),
      'idlingMinutes': _toInt(map['idlingMinutes']),
    };
  }).toList();
}

List<Map<String, dynamic>> _mapMaintenance(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw.whereType<Map>().map((item) {
    final map = _stringMap(item);
    return {
      ...map,
      'vehicle': _cleanString(map['vehicle'], fallback: 'Unknown'),
      'type': _cleanString(map['type'], fallback: 'Maintenance'),
      'description': _cleanString(
        map['description'],
        fallback: 'No maintenance details available.',
      ),
      'status': _cleanString(map['status'], fallback: 'scheduled'),
      'cost': _cleanString(map['cost'], fallback: 'N/A'),
      'date': _cleanString(map['date'], fallback: ''),
      'mileage': _cleanString(map['mileage'], fallback: '0'),
      'priority': _cleanString(map['priority'], fallback: 'Low'),
    };
  }).toList();
}

List<Map<String, dynamic>> _mapBillings(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw.whereType<Map>().map((item) {
    final map = _stringMap(item);
    return {
      ...map,
      'id': _cleanString(map['id'], fallback: 'INV-SYNCED'),
      'invoiceNumber': _cleanString(
        map['invoiceNumber'],
        fallback: 'INV-SYNCED',
      ),
      'client': _cleanString(map['client'], fallback: 'Geotab Trip'),
      'tripId': _cleanString(map['tripId'], fallback: 'TRP-SYNCED'),
      'issueDate': _cleanString(map['issueDate'], fallback: ''),
      'dueDate': _cleanString(map['dueDate'], fallback: ''),
      'status': _cleanString(map['status'], fallback: 'sent'),
      'amount': _cleanString(map['amount'], fallback: 'PHP 0.00'),
      'baseRate': _cleanString(map['baseRate'], fallback: 'PHP 0.00'),
      'distanceCost': _cleanString(map['distanceCost'], fallback: 'PHP 0.00'),
      'fuelCost': _cleanString(map['fuelCost'], fallback: 'PHP 0.00'),
      'driverPay': _cleanString(map['driverPay'], fallback: 'PHP 0.00'),
      'helperPay': _cleanString(map['helperPay'], fallback: 'PHP 0.00'),
      'tollFees': _cleanString(map['tollFees'], fallback: 'PHP 0.00'),
      'parking': _cleanString(map['parking'], fallback: 'PHP 0.00'),
      'maintenanceAlloc': _cleanString(
        map['maintenanceAlloc'],
        fallback: 'PHP 0.00',
      ),
      'insuranceAlloc': _cleanString(
        map['insuranceAlloc'],
        fallback: 'PHP 0.00',
      ),
      'subtotal': _cleanString(map['subtotal'], fallback: 'PHP 0.00'),
      'serviceFee': _cleanString(map['serviceFee'], fallback: 'PHP 0.00'),
      'vat': _cleanString(map['vat'], fallback: 'PHP 0.00'),
      'discount': _cleanString(map['discount'], fallback: '-PHP 0.00'),
    };
  }).toList();
}

List<NotificationItem> _mapNotifications(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw.whereType<Map>().map((item) {
    final map = _stringMap(item);
    final timestampText = map['timestamp']?.toString() ?? '';

    return NotificationItem(
      id: _cleanString(
        map['id'],
        fallback: 'notif-${DateTime.now().millisecondsSinceEpoch}',
      ),
      title: _cleanString(map['title'], fallback: 'Fleet Update'),
      message: _cleanString(map['message'], fallback: ''),
      time: _cleanString(map['time'], fallback: 'Now'),
      timestamp: DateTime.tryParse(timestampText) ?? DateTime.now(),
      category: _notificationCategory(map['category']?.toString()),
      isRead: map['isRead'] == true,
    );
  }).toList();
}

Map<String, dynamic> _stringMap(dynamic item) {
  if (item is! Map) {
    return {};
  }

  return item.map((key, value) => MapEntry(key.toString(), value));
}

List<Map<String, dynamic>> _mapNestedList(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .cast<Map<String, dynamic>>()
      .toList();
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw
      .map((value) => value?.toString().trim() ?? '')
      .where((value) => value.isNotEmpty)
      .toList();
}

String _cleanString(dynamic value, {required String fallback}) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String? _nullableString(dynamic value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

int _toInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _toDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}

String _normalizeVehicleStatus(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'on trip':
    case 'ontrip':
    case 'dispatched':
      return 'on trip';
    case 'maintenance':
      return 'maintenance';
    default:
      return 'available';
  }
}

String _normalizeDriverStatus(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'on trip':
    case 'dispatched':
      return 'on trip';
    default:
      return 'available';
  }
}

String _normalizeTripStatus(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'in progress':
    case 'inprogress':
      return 'in progress';
    case 'dispatched':
      return 'dispatched';
    case 'completed':
      return 'completed';
    case 'pending_approval':
      return 'pending_approval';
    case 'cancelled':
    case 'canceled':
      return 'cancelled';
    default:
      return 'pending';
  }
}

Color _vehicleStatusColor(String status) {
  switch (status) {
    case 'on trip':
      return AppTheme.colorFF4B7BE5;
    case 'maintenance':
      return AppTheme.colorFFF39C12;
    default:
      return AppTheme.colorFF27AE60;
  }
}

Color _driverStatusColor(String status) {
  return status == 'on trip' ? AppTheme.colorFF4B7BE5 : AppTheme.colorFF27AE60;
}

Color _tripStatusColor(String status) {
  switch (status) {
    case 'completed':
      return AppTheme.colorFF27AE60;
    case 'dispatched':
    case 'in progress':
      return AppTheme.colorFF4B7BE5;
    case 'pending_approval':
      return AppTheme.colorFF9B59B6;
    case 'cancelled':
      return AppTheme.colorFF6B7280;
    default:
      return AppTheme.colorFFF39C12;
  }
}

NotificationCategory _notificationCategory(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'maintenance':
      return NotificationCategory.maintenance;
    case 'trip':
      return NotificationCategory.trip;
    case 'fuel':
      return NotificationCategory.fuel;
    case 'driver':
      return NotificationCategory.driver;
    case 'billing':
      return NotificationCategory.billing;
    case 'alert':
      return NotificationCategory.alert;
    default:
      return NotificationCategory.system;
  }
}
