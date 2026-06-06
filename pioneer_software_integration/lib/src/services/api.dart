import 'dart:convert';

import 'auth.dart';
import 'backend_api.dart';
import 'billing_store.dart';
import 'driver_data_service.dart';
import 'fleet_sync_service.dart';
import 'maintenance_store.dart';
import 'drivers_store.dart';
import 'role_service.dart';
import 'trips_store.dart';
import 'vehicles_store.dart';

class Api {
  static Future<Map<String, dynamic>> getDashboard() async {
    if (AuthService.currentRole == UserRole.driver) {
      await _refreshDriverTripsFromBackend();
      return {
        'todayStats': DriverDataService.getTodayStats(),
        'currentTrip': DriverDataService.getCurrentTrip(),
        'upcomingTrips': DriverDataService.getUpcomingTrips(),
        'weekSummary': DriverDataService.getWeekSummary(),
      };
    }

    // Page-level consumers should attach to the shared startup/store pipeline
    // instead of blocking on a fresh summary request here.
    refreshFleetBootstrapSilently();
    refreshFleetBootstrap()
        .then((_) => refreshFleetSnapshotSilently())
        .catchError((_) {});

    return _getDashboardData();
  }

  static Future<List<Map<String, dynamic>>> getDriverTrips() async {
    await _refreshDriverTripsFromBackend();
    return DriverDataService.getDriverTrips();
  }

  static Future<Map<String, dynamic>?> getDriverVehicle() async {
    await _refreshDriverTripsFromBackend();
    final vehicle = DriverDataService.getDriverVehicle();
    if (vehicle != null) {
      return vehicle;
    }

    return {
      'plate': 'Unassigned',
      'model': 'N/A',
      'year': 'N/A',
      'status': 'Unassigned',
      'fuel': 0.0,
      'mileage': '0',
      'lastInspection': 'N/A',
      'nextMaintenance': 'N/A',
      'truckType': 'N/A',
      'fuelCapacity': 0,
      'numTrips': 0,
      'documents': <Map<String, dynamic>>[],
    };
  }

  static Future<Map<String, dynamic>> getDriverEarnings() async {
    await _refreshDriverTripsFromBackend();
    return DriverDataService.getEarningsData();
  }

  static Future<List<Map<String, dynamic>>> getVehicleLocations() async {
    if (AuthService.currentRole == UserRole.driver) {
      await _refreshDriverTripsFromBackend();
      final trip = DriverDataService.getCurrentTrip();
      final tripId = trip?['tripId']?.toString().trim() ?? '';
      if (tripId.isEmpty || tripId == 'N/A') {
        return const [];
      }

      final map = await BackendApiService.getTripMap(tripId);
      final trail = (map['actualTrail'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (point) =>
                point.map((key, value) => MapEntry(key.toString(), value)),
          )
          .where((point) {
            final latitude = (point['latitude'] as num?)?.toDouble() ?? 0.0;
            final longitude = (point['longitude'] as num?)?.toDouble() ?? 0.0;
            return latitude != 0.0 || longitude != 0.0;
          })
          .toList();
      if (trail.isEmpty) {
        return const [];
      }

      final latest = trail.last;
      return [
        {
          'plate': map['vehicle'] ?? trip?['vehicle'] ?? 'Assigned vehicle',
          'latitude': latest['latitude'],
          'longitude': latest['longitude'],
          'speed': latest['speed'] ?? 0,
          'status': map['status'] ?? trip?['status'] ?? 'active',
          'driver': AuthService.currentUserData?.fullName ?? 'Driver',
          'destination': map['destination'] ?? trip?['dropoff'] ?? '',
          'heading': 0.0,
          'lastUpdated': latest['dateTime'],
          'authorizedTrail': trail,
        },
      ];
    } else {
      try {
        await refreshVehicleLocationsFromBackend();
        final hasTrackedVehicles = vehiclesNotifier.value.any((vehicle) {
          final latitude = (vehicle['latitude'] as num?)?.toDouble() ?? 0.0;
          final longitude = (vehicle['longitude'] as num?)?.toDouble() ?? 0.0;
          return latitude != 0.0 || longitude != 0.0;
        });
        if (!hasTrackedVehicles) {
          await refreshVehiclesFromBackend();
          await refreshVehicleLocationsFromBackend();
        }
      } on BackendApiException {
        // Fall back to local state when the backend is not reachable.
      } catch (_) {
        // Fall back to local state when the backend is not reachable.
      }
    }

    final trackedVehicles = vehiclesNotifier.value.where((vehicle) {
      final latitude = (vehicle['latitude'] as num?)?.toDouble() ?? 0.0;
      final longitude = (vehicle['longitude'] as num?)?.toDouble() ?? 0.0;
      return latitude != 0.0 || longitude != 0.0;
    }).toList();

    if (AuthService.currentRole == UserRole.driver) {
      final currentTrip = DriverDataService.getCurrentTrip();
      final driverVehicle = DriverDataService.getDriverVehicle();

      final matchedVehicle = trackedVehicles
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (vehicle) =>
                vehicle?['plate']?.toString().toLowerCase() ==
                driverVehicle?['plate']?.toString().toLowerCase(),
            orElse: () => null,
          );

      if (matchedVehicle != null) {
        return [
          {
            'plate':
                matchedVehicle['plate'] ?? driverVehicle?['plate'] ?? 'N/A',
            'latitude': matchedVehicle['latitude'] ?? 14.5995,
            'longitude': matchedVehicle['longitude'] ?? 120.9842,
            'speed': matchedVehicle['speed'] ?? 0,
            'status': matchedVehicle['status'] ?? 'available',
            'driver':
                AuthService.currentUserData?.fullName ??
                matchedVehicle['driver'] ??
                'Driver',
            'destination':
                currentTrip?['dropoff'] ??
                matchedVehicle['comment'] ??
                'Live Geotab tracking',
            'heading': matchedVehicle['bearing'] ?? 0,
            'geotabId': matchedVehicle['geotabId'],
            'lastUpdated': matchedVehicle['lastUpdated'],
          },
        ];
      }

      return [
        {
          'plate': driverVehicle?['plate'] ?? 'N/A',
          'latitude': 0.0,
          'longitude': 0.0,
          'speed': 0,
          'status': driverVehicle?['status'] ?? 'N/A',
          'driver': AuthService.currentUserData?.fullName ?? 'Driver',
          'destination': currentTrip?['dropoff'] ?? 'No active delivery',
          'heading': 0.0,
        },
      ];
    }

    if (trackedVehicles.isNotEmpty) {
      return trackedVehicles.map((vehicle) {
        return {
          'plate': vehicle['plate'] ?? 'N/A',
          'latitude': vehicle['latitude'] ?? 0.0,
          'longitude': vehicle['longitude'] ?? 0.0,
          'speed': vehicle['speed'] ?? 0,
          'status': vehicle['status'] ?? 'available',
          'driver': vehicle['driver'] ?? 'Unassigned',
          'destination':
              vehicle['comment']?.toString().trim().isNotEmpty == true
              ? vehicle['comment']
              : 'Live Geotab tracking',
          'heading': vehicle['bearing'] ?? 0,
          'geotabId': vehicle['geotabId'],
          'lastUpdated': vehicle['lastUpdated'],
        };
      }).toList();
    }

    return vehiclesNotifier.value
        .where((vehicle) {
          final latitude = (vehicle['latitude'] as num?)?.toDouble() ?? 0.0;
          final longitude = (vehicle['longitude'] as num?)?.toDouble() ?? 0.0;
          return latitude != 0.0 || longitude != 0.0;
        })
        .map((vehicle) {
          return {
            'plate': vehicle['plate'] ?? 'N/A',
            'latitude': vehicle['latitude'] ?? 0.0,
            'longitude': vehicle['longitude'] ?? 0.0,
            'speed': vehicle['speed'] ?? 0,
            'status': vehicle['status'] ?? 'N/A',
            'driver': vehicle['driver'] ?? 'Unassigned',
            'destination':
                vehicle['comment']?.toString().trim().isNotEmpty == true
                ? vehicle['comment']
                : 'Live Geotab tracking',
            'heading': vehicle['bearing'] ?? 0,
            'geotabId': vehicle['geotabId'],
            'lastUpdated': vehicle['lastUpdated'],
          };
        })
        .toList();
  }

  static Future<void> _refreshDriverTripsFromBackend() async {
    if (AuthService.currentRole != UserRole.driver) {
      return;
    }

    final trips = await BackendApiService.getFleetTrips();
    if (jsonEncode(tripsNotifier.value) != jsonEncode(trips)) {
      tripsNotifier.value = trips;
    }
  }

  static Future<bool> updateTripStatus(String tripId, String status) async {
    try {
      if (status.toLowerCase() == 'completed') {
        await completeTripAndFreeResources(tripId);
      } else {
        final index = tripsNotifier.value.indexWhere(
          (trip) => trip['tripId'] == tripId,
        );
        if (index == -1) {
          return false;
        }

        await updateTrip(tripId, {'status': status});
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> _getDashboardData() {
    double totalRevenue = 0;
    for (final billing in billingsNotifier.value) {
      totalRevenue += _parseAmount(billing['amount']);
    }

    return {
      'dateLabel': _formatDateLabel(DateTime.now()),
      'stats': [
        {
          'title': 'Active Vehicles',
          'value': vehiclesNotifier.value
              .where(
                (vehicle) =>
                    vehicle['status'] == 'active' ||
                    vehicle['status'] == 'dispatched' ||
                    vehicle['status'] == 'on trip' ||
                    vehicle['status'] == 'available',
              )
              .length
              .toString(),
          'subtitle': 'Fleet utilization',
          'icon': 'truck',
        },
        {
          'title': 'Active Drivers',
          'value': driversNotifier.value
              .where(
                (driver) =>
                    driver['status'] == 'active' ||
                    driver['status'] == 'dispatched',
              )
              .length
              .toString(),
          'subtitle': 'On duty today',
          'icon': 'driver',
        },
        {
          'title': 'Trips Today',
          'value': tripsNotifier.value
              .where(
                (trip) =>
                    trip['status'] == 'completed' ||
                    trip['status'] == 'dispatched',
              )
              .length
              .toString(),
          'subtitle': 'Active and completed',
          'icon': 'trip',
        },
        {
          'title': 'Pending Queue',
          'value': tripsNotifier.value
              .where((trip) => trip['status'] == 'pending')
              .length
              .toString(),
          'subtitle': 'Awaiting dispatch',
          'icon': 'queue',
        },
        {
          'title': 'Alerts',
          'value': '3',
          'subtitle': '1 Critical',
          'icon': 'warning',
        },
      ],
      'maintenance': maintenanceNotifier.value.map((record) {
        return {
          'plate': record['vehicle'] ?? 'Unknown',
          'model': record['type'] ?? 'Maintenance',
          'risk': record['priority'] ?? 'Low',
          'issue': record['description'] ?? 'Maintenance item',
          'details': record['description'] ?? 'Maintenance item',
          'confidence': 50,
          'mileage': record['mileage'] ?? '0',
        };
      }).toList(),
      'totalRevenue': totalRevenue,
    };
  }

  static double _parseAmount(dynamic value) {
    final raw = value?.toString().replaceAll(RegExp(r'[^0-9.-]'), '') ?? '';
    return double.tryParse(raw) ?? 0;
  }

  static String _formatDateLabel(DateTime value) {
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    return '${weekdays[value.weekday - 1]}, ${months[value.month - 1]} ${value.day}, ${value.year}';
  }

  static Future<Map<String, dynamic>> getDriverDetails(
    String driverName,
  ) async {
    final drivers = driversNotifier.value;
    final index = drivers.indexWhere((driver) => driver['name'] == driverName);
    if (index == -1) {
      return {};
    }

    final driver = drivers[index];
    final trips = (driver['trips'] as num?)?.toInt() ?? 0;
    final delays = (driver['delays'] as num?)?.toInt() ?? 0;
    final score = (driver['score'] as num?) ?? 0;

    final vehicles = vehiclesNotifier.value;
    final assignedVehicle = vehicles.firstWhere(
      (vehicle) => vehicle['driver'] == driverName,
      orElse: () => <String, dynamic>{},
    );
    final vehicleDisplay = assignedVehicle.isNotEmpty
        ? '${assignedVehicle['truckType'] ?? ''} - ${assignedVehicle['plate'] ?? ''}'
        : 'Unassigned';

    final experienceYears = (trips / 25).ceil();

    return {
      'name': driver['name'] ?? driverName,
      'status': driver['status'] ?? 'available',
      'rating': (score / 20).toDouble(),
      'safetyScore': score,
      'onTimePercentage': trips > 0
          ? ((trips - delays) / trips * 100).round()
          : 100,
      'license': driver['license'] ?? 'N/A',
      'licenseExpiry': driver['licenseExpiry'] ?? 'N/A',
      'phone': driver['phone'] ?? 'N/A',
      'email': driver['email'] ?? 'N/A',
      'joinDate': driver['joinDate'] ?? 'N/A',
      'experience': '$experienceYears yr${experienceYears != 1 ? 's' : ''}',
      'totalTrips': trips,
      'totalDistance': 'N/A',
      'violations': delays,
      'currentVehicle': vehicleDisplay,
    };
  }
}
