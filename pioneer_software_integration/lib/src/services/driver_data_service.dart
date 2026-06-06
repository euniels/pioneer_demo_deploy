import 'auth.dart';
import 'maintenance_store.dart';
import 'trips_store.dart';
import 'vehicles_store.dart';

class DriverDataService {
  static String get _driverName => AuthService.currentUserData?.fullName ?? '';

  static List<Map<String, dynamic>> getDriverTrips() {
    final name = _driverName;
    if (name.isEmpty) {
      return [];
    }

    return tripsNotifier.value
        .where((trip) => (trip['driver'] ?? '').toString() == name)
        .map(_mapTripForDriver)
        .toList();
  }

  static Map<String, dynamic>? getCurrentTrip() {
    final name = _driverName;
    if (name.isEmpty) {
      return null;
    }

    final activeTrips = tripsNotifier.value.where((trip) {
      final driver = (trip['driver'] ?? '').toString();
      final status = (trip['status'] ?? '').toString().toLowerCase();
      return driver == name &&
          (status == 'dispatched' ||
              status == 'in progress' ||
              status == 'inprogress' ||
              status == 'pending_approval');
    }).toList();

    if (activeTrips.isEmpty) {
      return null;
    }

    return _mapCurrentTrip(activeTrips.first);
  }

  static List<Map<String, dynamic>> getUpcomingTrips() {
    final name = _driverName;
    if (name.isEmpty) {
      return [];
    }

    return tripsNotifier.value
        .where((trip) {
          final driver = (trip['driver'] ?? '').toString();
          final status = (trip['status'] ?? '').toString().toLowerCase();
          return driver == name && status == 'pending';
        })
        .map(_mapUpcomingTrip)
        .toList();
  }

  static List<Map<String, dynamic>> getCompletedTrips() {
    final name = _driverName;
    if (name.isEmpty) {
      return [];
    }

    return tripsNotifier.value
        .where((trip) {
          final driver = (trip['driver'] ?? '').toString();
          final status = (trip['status'] ?? '').toString().toLowerCase();
          return driver == name && status == 'completed';
        })
        .map(_mapTripForDriver)
        .toList();
  }

  static Map<String, dynamic> getTodayStats() {
    final allTrips = getDriverTrips();
    final completed = allTrips
        .where(
          (trip) =>
              (trip['status'] ?? '').toString().toLowerCase() == 'completed',
        )
        .toList();
    final inProgress = allTrips.where((trip) {
      final status = (trip['status'] ?? '').toString().toLowerCase();
      return status == 'dispatched' ||
          status == 'in progress' ||
          status == 'awaiting approval';
    }).toList();

    final totalEarnings = completed.fold<double>(
      0,
      (sum, trip) => sum + _parseAmount(trip['payment']),
    );

    return {
      'tripsCompleted': completed.length,
      'tripsAssigned': allTrips.length,
      'inProgress': inProgress.length,
      'earnings': _formatCurrency(totalEarnings),
      'distance':
          '${completed.fold<double>(0, (sum, trip) => sum + _parseDouble(trip['distanceKm']))} km',
      'hoursWorked':
          '${(completed.fold<int>(0, (sum, trip) => sum + _parseInt(trip['drivingMinutes'])) / 60).toStringAsFixed(1)} hrs',
      'rating': '4.8',
    };
  }

  static Map<String, dynamic> getWeekSummary() {
    final completed = getCompletedTrips();
    final totalEarnings = completed.fold<double>(
      0,
      (sum, trip) => sum + _parseAmount(trip['payment']),
    );
    final totalDistance = completed.fold<double>(
      0,
      (sum, trip) => sum + _parseDouble(trip['distanceKm']),
    );

    return {
      'totalTrips': completed.length,
      'totalEarnings': _formatCurrency(totalEarnings),
      'avgRating': '4.8',
      'onTimeRate': completed.isEmpty ? 0 : 100,
      'totalDistance': '${totalDistance.toStringAsFixed(1)} km',
    };
  }

  static Map<String, dynamic>? getDriverVehicle() {
    final name = _driverName;
    if (name.isEmpty) {
      return null;
    }

    final assigned = vehiclesNotifier.value.where((vehicle) {
      return (vehicle['driver'] ?? '').toString() == name;
    }).toList();

    if (assigned.isNotEmpty) {
      return _mapVehicleForDriver(assigned.first);
    }

    final currentTrip = getCurrentTrip();
    if (currentTrip != null) {
      final vehiclePlate = currentTrip['vehicle']?.toString() ?? '';
      final vehicle = vehiclesNotifier.value
          .cast<Map<String, dynamic>?>()
          .firstWhere(
            (entry) => entry?['plate']?.toString() == vehiclePlate,
            orElse: () => null,
          );
      if (vehicle != null) {
        return _mapVehicleForDriver(vehicle);
      }
    }

    return null;
  }

  static Map<String, dynamic> getEarningsData() {
    final completed = getCompletedTrips();
    final total = completed.fold<double>(
      0,
      (sum, trip) => sum + _parseAmount(trip['payment']),
    );

    final Map<String, double> byDate = {};
    for (final trip in completed) {
      final date = (trip['date'] ?? 'Unknown').toString();
      byDate[date] = (byDate[date] ?? 0) + _parseAmount(trip['payment']);
    }

    final breakdown = byDate.entries
        .map(
          (entry) => {
            'date': entry.key,
            'trips': completed
                .where((trip) => trip['date'] == entry.key)
                .length,
            'amount': _formatCurrency(entry.value),
            'hours': _formatHours(
              completed
                  .where((trip) => trip['date'] == entry.key)
                  .fold<int>(
                    0,
                    (sum, trip) => sum + _parseInt(trip['drivingMinutes']),
                  ),
            ),
          },
        )
        .toList();

    final recentTrips = completed.take(4).map((trip) {
      return {
        'tripId': trip['id'] ?? 'N/A',
        'route': '${trip['pickup'] ?? 'N/A'} -> ${trip['dropoff'] ?? 'N/A'}',
        'date': trip['date'] ?? 'N/A',
        'amount': trip['payment'] ?? _formatCurrency(0),
        'status': 'Completed',
      };
    }).toList();

    final inProgress = tripsNotifier.value.where((trip) {
      final driver = (trip['driver'] ?? '').toString();
      final status = (trip['status'] ?? '').toString().toLowerCase();
      return driver == _driverName &&
          (status == 'in progress' ||
              status == 'inprogress' ||
              status == 'dispatched' ||
              status == 'pending_approval');
    }).toList();

    final pendingTotal = inProgress.fold<double>(
      0,
      (sum, trip) => sum + _parseAmount(trip['amount']),
    );

    final now = DateTime.now();
    final daysUntilFriday = (DateTime.friday - now.weekday + 7) % 7;
    final nextFriday = now.add(
      Duration(days: daysUntilFriday == 0 ? 7 : daysUntilFriday),
    );

    return {
      'today': {
        'amount': _formatCurrency(total),
        'trips': completed.length,
        'hours': _formatHours(
          completed.fold<int>(
            0,
            (sum, trip) => sum + _parseInt(trip['drivingMinutes']),
          ),
        ),
      },
      'thisWeek': {
        'amount': _formatCurrency(total),
        'trips': completed.length,
        'hours': _formatHours(
          completed.fold<int>(
            0,
            (sum, trip) => sum + _parseInt(trip['drivingMinutes']),
          ),
        ),
      },
      'thisMonth': {
        'amount': _formatCurrency(total),
        'trips': completed.length,
        'hours': _formatHours(
          completed.fold<int>(
            0,
            (sum, trip) => sum + _parseInt(trip['drivingMinutes']),
          ),
        ),
      },
      'pendingPayments': _formatCurrency(pendingTotal),
      'nextPayoutDate':
          '${_monthLabel(nextFriday.month)} ${nextFriday.day}, ${nextFriday.year}',
      'breakdown': breakdown,
      'recentTrips': recentTrips,
    };
  }

  static String? findRealTripId(String driverTripId) {
    final match = tripsNotifier.value.where((trip) {
      return (trip['tripId'] ?? '').toString() == driverTripId;
    }).toList();
    return match.isEmpty ? null : match.first['tripId'] as String?;
  }

  static Map<String, dynamic> _mapTripForDriver(Map<String, dynamic> trip) {
    return {
      'id': trip['tripId'] ?? 'N/A',
      'pickup': trip['origin'] ?? 'N/A',
      'dropoff': trip['destination'] ?? 'N/A',
      'customer': trip['customer'] ?? 'Geotab Trip',
      'payment': trip['amount'] ?? _formatCurrency(0),
      'earnings': trip['amount'] ?? _formatCurrency(0),
      'date': trip['date'] ?? 'N/A',
      'time': trip['date'] ?? 'N/A',
      'distance': '${_parseDouble(trip['distanceKm']).toStringAsFixed(1)} km',
      'distanceKm': _parseDouble(trip['distanceKm']),
      'duration': _formatHours(_parseInt(trip['drivingMinutes'])),
      'drivingMinutes': _parseInt(trip['drivingMinutes']),
      'status': _mapStatus(trip['status'] ?? ''),
      'cargo': trip['customer'] ?? 'General freight',
      'notes': trip['notes'] ?? '',
    };
  }

  static Map<String, dynamic> _mapCurrentTrip(Map<String, dynamic> trip) {
    return {
      'tripId': trip['tripId'] ?? 'N/A',
      'pickup': trip['origin'] ?? 'N/A',
      'dropoff': trip['destination'] ?? 'N/A',
      'customer': trip['customer'] ?? 'Geotab Trip',
      'vehicle': trip['vehicle'] ?? 'N/A',
      'status': _mapStatus(trip['status'] ?? ''),
      'estimatedArrival': trip['date'] ?? 'N/A',
      'distance': '${_parseDouble(trip['distanceKm']).toStringAsFixed(1)} km',
      'cargo': trip['customer'] ?? 'General freight',
    };
  }

  static Map<String, dynamic> _mapUpcomingTrip(Map<String, dynamic> trip) {
    return {
      'tripId': trip['tripId'] ?? 'N/A',
      'pickup': trip['origin'] ?? 'N/A',
      'dropoff': trip['destination'] ?? 'N/A',
      'customer': trip['customer'] ?? 'Geotab Trip',
      'time': trip['date'] ?? 'N/A',
      'payment': trip['amount'] ?? _formatCurrency(0),
    };
  }

  static Map<String, dynamic> _mapVehicleForDriver(
    Map<String, dynamic> vehicle,
  ) {
    final plate = (vehicle['plate'] ?? '').toString();
    final maintenance = maintenanceNotifier.value
        .cast<Map<String, dynamic>?>()
        .firstWhere(
          (record) => record?['vehicle']?.toString() == plate,
          orElse: () => null,
        );

    final documents =
        (vehicle['documents'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        <Map<String, dynamic>>[];

    return {
      'plate': plate.isEmpty ? 'Unassigned' : plate,
      'model': vehicle['truckType'] ?? 'Truck',
      'year': vehicle['year'] ?? 'N/A',
      'status': _mapVehicleStatus(vehicle['status']),
      'fuel': _parseDouble(vehicle['fuelLevelRatio']).clamp(0.0, 1.0),
      'mileage': (vehicle['mileage'] ?? '0').toString(),
      'lastInspection': vehicle['lastInspection'] ?? 'N/A',
      'nextMaintenance':
          maintenance?['date']?.toString() ??
          vehicle['nextMaintenance']?.toString() ??
          'N/A',
      'truckType': vehicle['truckType'] ?? 'Truck',
      'fuelCapacity': _parseInt(vehicle['fuelCapacity']),
      'numTrips': _parseInt(vehicle['numTrips']),
      'totalRevenue': _parseAmount(vehicle['totalRevenue']),
      'documents': documents,
    };
  }

  static String _mapStatus(dynamic raw) {
    switch (raw.toString().toLowerCase()) {
      case 'dispatched':
        return 'In Progress';
      case 'inprogress':
      case 'in progress':
        return 'In Progress';
      case 'pending_approval':
        return 'Awaiting Approval';
      case 'completed':
        return 'Completed';
      case 'pending':
        return 'Pending';
      default:
        return raw.toString().isEmpty ? 'Pending' : raw.toString();
    }
  }

  static String _mapVehicleStatus(dynamic raw) {
    switch (raw.toString().toLowerCase()) {
      case 'on trip':
      case 'dispatched':
        return 'On Trip';
      case 'maintenance':
        return 'Maintenance';
      case 'available':
        return 'Available';
      default:
        return raw.toString().isEmpty ? 'Available' : raw.toString();
    }
  }

  static double _parseAmount(dynamic value) {
    final raw = value?.toString().replaceAll(RegExp(r'[^0-9.-]'), '') ?? '';
    return double.tryParse(raw) ?? 0;
  }

  static double _parseDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int _parseInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _formatCurrency(double amount) {
    return 'PHP ${amount.toStringAsFixed(2)}';
  }

  static String _formatHours(int drivingMinutes) {
    final hours = drivingMinutes / 60;
    return hours.toStringAsFixed(1);
  }

  static String _monthLabel(int month) {
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
    return months[month];
  }
}
