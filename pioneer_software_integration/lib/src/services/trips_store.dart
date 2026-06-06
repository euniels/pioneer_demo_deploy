// lib/src/services/trips_store.dart
import 'dart:async';

import 'package:flutter/material.dart';

import 'backend_api.dart';
import 'drivers_store.dart';
import 'local_fleet_mirror_service.dart';
import 'notification_service.dart';
import 'vehicles_store.dart';
import '../theme/app_theme.dart';

final ValueNotifier<List<Map<String, dynamic>>> tripsNotifier =
    ValueNotifier<List<Map<String, dynamic>>>(_initialTrips());

List<Map<String, dynamic>> _initialTrips() => [];

Future<Map<String, dynamic>> addTrip(Map<String, dynamic> trip) async {
  final previous = tripsNotifier.value
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  tripsNotifier.value = [trip, ...tripsNotifier.value];
  _persistTripsMirror();
  try {
    final result = await BackendApiService.createTrip({
      'tripId': trip['tripId'],
      'customer': trip['customer'],
      'phone': trip['phone'],
      'origin': trip['origin'],
      'destination': trip['destination'],
      'cargoType': trip['cargoType'],
      'totalWeightKg': trip['totalWeightKg'],
      'orderValue': _parseCurrency(trip['orderValue'] ?? trip['amount']),
      'vehicle': trip['vehicle'],
      'driver': trip['driver'],
      'scheduledDepartureAt': trip['scheduledDepartureAt'],
      'estimatedArrivalAt': trip['estimatedArrivalAt'],
      'specialInstructions': trip['specialInstructions'],
      'freeDeliveryCandidate': trip['freeDeliveryCandidate'],
      'status': trip['status'],
      'workflowPhaseNumber': trip['workflowPhaseNumber'] ?? 1,
      'amount': _parseCurrency(trip['amount']),
      'notes': trip['notes'] ?? 'Created from dispatch workflow.',
    });
    final saved = {
      ...trip,
      ...result,
      'statusColor': _tripStatusColor(result['status'] ?? trip['status']),
    };
    tripsNotifier.value = tripsNotifier.value.map((item) {
      return item['tripId'] == trip['tripId'] ? saved : item;
    }).toList();
    _persistTripsMirror();
    final svc = NotificationService.instance;
    svc.addNotification(
      NotificationItem(
        id: svc.nextId(),
        title: 'New Trip Scheduled - ${trip['tripId']}',
        message:
            '${trip['customer']} requested a trip from ${trip['origin']} to ${trip['destination']}. Amount: ${trip['amount']}.',
        time: 'Just now',
        timestamp: DateTime.now(),
        category: NotificationCategory.trip,
        isRead: false,
      ),
    );
    return saved;
  } catch (_) {
    tripsNotifier.value = previous;
    _persistTripsMirror();
    rethrow;
  }
}

Future<Map<String, dynamic>> updateTrip(
  String tripId,
  Map<String, dynamic> updates,
) async {
  final previous = tripsNotifier.value
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
  tripsNotifier.value = tripsNotifier.value.map((trip) {
    if (trip['tripId'] == tripId) {
      return {...trip, ...updates};
    }
    return trip;
  }).toList();
  _persistTripsMirror();
  try {
    final result = await BackendApiService.updateTrip(tripId, {
      if (updates.containsKey('customer')) 'customer': updates['customer'],
      if (updates.containsKey('phone')) 'phone': updates['phone'],
      if (updates.containsKey('origin')) 'origin': updates['origin'],
      if (updates.containsKey('destination'))
        'destination': updates['destination'],
      if (updates.containsKey('cargoType')) 'cargoType': updates['cargoType'],
      if (updates.containsKey('totalWeightKg'))
        'totalWeightKg': updates['totalWeightKg'],
      if (updates.containsKey('orderValue'))
        'orderValue': _parseCurrency(updates['orderValue']),
      if (updates.containsKey('vehicle')) 'vehicle': updates['vehicle'],
      if (updates.containsKey('driver')) 'driver': updates['driver'],
      if (updates.containsKey('scheduledDepartureAt'))
        'scheduledDepartureAt': updates['scheduledDepartureAt'],
      if (updates.containsKey('estimatedArrivalAt'))
        'estimatedArrivalAt': updates['estimatedArrivalAt'],
      if (updates.containsKey('specialInstructions'))
        'specialInstructions': updates['specialInstructions'],
      if (updates.containsKey('cancellationReason'))
        'cancellationReason': updates['cancellationReason'],
      if (updates.containsKey('cancelledAt'))
        'cancelledAt': updates['cancelledAt'],
      if (updates.containsKey('freeDeliveryCandidate'))
        'freeDeliveryCandidate': updates['freeDeliveryCandidate'],
      if (updates.containsKey('status')) 'status': updates['status'],
      if (updates.containsKey('notes')) 'notes': updates['notes'],
      if (updates.containsKey('amount'))
        'amount': _parseCurrency(updates['amount']),
      if (updates.containsKey('startedAt')) 'startedAt': updates['startedAt'],
      if (updates.containsKey('endedAt')) 'endedAt': updates['endedAt'],
      if (updates.containsKey('workflowPhaseNumber'))
        'workflowPhaseNumber': updates['workflowPhaseNumber'],
    });
    final merged = tripsNotifier.value.map((trip) {
      if (trip['tripId'] != tripId) return trip;
      final saved = {...trip, ...result};
      return {...saved, 'statusColor': _tripStatusColor(saved['status'])};
    }).toList();
    tripsNotifier.value = merged;
    _persistTripsMirror();
    return merged.firstWhere((trip) => trip['tripId'] == tripId);
  } catch (_) {
    tripsNotifier.value = previous;
    _persistTripsMirror();
    rethrow;
  }
}

void deleteTrip(String tripId) {
  tripsNotifier.value = tripsNotifier.value
      .where((trip) => trip['tripId'] != tripId)
      .toList();
  _persistTripsMirror();
}

String _formatNow() {
  final now = DateTime.now();
  const months = [
    '',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour);
  final minute = now.minute.toString().padLeft(2, '0');
  final meridian = now.hour >= 12 ? 'PM' : 'AM';
  return '${months[now.month]} ${now.day}, $hour:$minute $meridian';
}

Future<void> requestTripCompletion(
  String tripId, {
  required String driverNotes,
}) async {
  final trips = tripsNotifier.value;
  final index = trips.indexWhere((trip) => trip['tripId'] == tripId);
  if (index == -1) {
    return;
  }

  final trip = trips[index];
  final driverName = trip['driver']?.toString() ?? '';

  final updatedTrip = {
    ...trip,
    'status': 'pending_approval',
    'statusColor': AppTheme.colorFF9B59B6,
    'driverNotes': driverNotes,
    'clientSignatureCaptured': true,
    'completionRequestedBy': driverName,
    'completionRequestedAt': _formatNow(),
  };

  final updatedTrips = [...trips];
  updatedTrips[index] = updatedTrip;
  tripsNotifier.value = updatedTrips;
  _persistTripsMirror();
  try {
    await BackendApiService.updateTrip(tripId, {
      'status': 'pending_approval',
      'notes': driverNotes,
      'driver': driverName,
    });
  } catch (_) {
    tripsNotifier.value = trips;
    _persistTripsMirror();
    rethrow;
  }

  final svc = NotificationService.instance;
  svc.addNotification(
    NotificationItem(
      id: svc.nextId(),
      title: 'Trip Awaits Approval - ${trip['tripId']}',
      message:
          '$driverName has completed delivery for ${trip['customer']}. Please review and approve.',
      time: 'Just now',
      timestamp: DateTime.now(),
      category: NotificationCategory.trip,
      isRead: false,
    ),
  );
}

Future<void> completeTripAndFreeResources(String tripId) async {
  final trips = tripsNotifier.value;
  final index = trips.indexWhere((trip) => trip['tripId'] == tripId);

  if (index == -1) {
    return;
  }

  final trip = trips[index];
  final vehiclePlate = trip['vehicle']?.toString() ?? '';
  final driverName = trip['driver']?.toString() ?? '';
  final tripAmount = _parseCurrency(trip['amount']);

  final updatedTrip = {
    ...trip,
    'status': 'completed',
    'statusColor': AppTheme.colorFF10B981,
  };

  final updatedTrips = [...trips];
  updatedTrips[index] = updatedTrip;
  tripsNotifier.value = updatedTrips;
  _persistTripsMirror();
  try {
    await BackendApiService.updateTrip(tripId, {
      'status': 'completed',
      'vehicle': vehiclePlate,
      'driver': driverName,
      'endedAt': DateTime.now().toIso8601String(),
      'workflowPhaseNumber': 12,
    });
  } catch (_) {
    tripsNotifier.value = trips;
    _persistTripsMirror();
    rethrow;
  }

  if (vehiclePlate.isNotEmpty && vehiclePlate != 'N/A') {
    final vehicles = vehiclesNotifier.value;
    final vehicleIndex = vehicles.indexWhere((vehicle) {
      return vehicle['plate'] == vehiclePlate;
    });

    if (vehicleIndex != -1) {
      final vehicle = vehicles[vehicleIndex];
      final currentTrips = (vehicle['numTrips'] as int?) ?? 0;
      final currentRevenue = (vehicle['totalRevenue'] as int?) ?? 0;
      final newNumTrips = currentTrips + 1;
      final newTotalRevenue = currentRevenue + tripAmount;

      if (vehicle['pendingMaintenanceStatus'] == true) {
        updateVehicle(vehiclePlate, {
          'status': 'maintenance',
          'statusColor': AppTheme.colorFFF39C12,
          'pendingMaintenanceStatus': null,
          'driver': 'Unassigned',
          'numTrips': newNumTrips,
          'totalRevenue': newTotalRevenue,
        });
      } else {
        updateVehicle(vehiclePlate, {
          'status': 'available',
          'statusColor': AppTheme.colorFF27AE60,
          'driver': 'Unassigned',
          'numTrips': newNumTrips,
          'totalRevenue': newTotalRevenue,
        });
      }
    }
  }

  if (driverName.isNotEmpty && driverName != 'Unassigned') {
    updateDriverStatus(driverName, 'available');
    updateDriverTripStats(driverName, tripAmount);
  }

  final svc = NotificationService.instance;
  svc.addNotification(
    NotificationItem(
      id: svc.nextId(),
      title: 'Trip Completed - ${trip['tripId']}',
      message:
          '${trip['customer']} delivery completed by ${driverName.isNotEmpty ? driverName : 'driver'}. Amount: ${trip['amount']}.',
      time: 'Just now',
      timestamp: DateTime.now(),
      category: NotificationCategory.trip,
      isRead: false,
    ),
  );
}

int _parseCurrency(dynamic value) {
  final raw = value?.toString().replaceAll(RegExp(r'[^0-9.-]'), '') ?? '';
  return double.tryParse(raw)?.round() ?? 0;
}

Color _tripStatusColor(dynamic value) {
  return switch (value?.toString().trim().toLowerCase().replaceAll(' ', '')) {
    'completed' => AppTheme.colorFF10B981,
    'cancelled' || 'canceled' => AppTheme.colorFF6B7280,
    'dispatched' || 'inprogress' || 'ontrip' => AppTheme.colorFF4B7BE5,
    'pending_approval' || 'pendingapproval' => AppTheme.colorFF9B59B6,
    _ => AppTheme.colorFFF39C12,
  };
}

void _persistTripsMirror() {
  unawaited(
    LocalFleetMirrorService.replaceTrips(
      tripsNotifier.value,
    ).catchError((_) {}),
  );
}
