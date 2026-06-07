import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/local_fleet_mirror_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await LocalFleetMirrorService.initialize();
    await LocalFleetMirrorService.resetForTesting();
  });

  test(
    'mirrors stable fleet summary data and excludes live GPS fields',
    () async {
      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 45));

      await LocalFleetMirrorService.mirrorResponse('/fleet/summary', {
        'success': true,
        'data': {
          'vehicles': [
            {
              'plate': 'NGO7290',
              'geotabId': 'b1',
              'truckType': 'Wing Van',
              'latitude': 14.1,
              'longitude': 121.1,
              'speed': 42,
              'bearing': 90,
            },
          ],
          'drivers': [
            {'id': 'drv-1', 'name': 'Juan Driver', 'status': 'available'},
          ],
          'trips': [
            {
              'tripId': 'TRP-RECENT',
              'status': 'pending',
              'createdAt': now.toIso8601String(),
            },
            {
              'tripId': 'TRP-OLD',
              'status': 'completed',
              'createdAt': old.toIso8601String(),
            },
          ],
          'notifications': [
            {
              'id': 'notif-1',
              'title': 'Dispatch ready',
              'timestamp': now.toIso8601String(),
            },
          ],
        },
      });

      final state = await LocalFleetMirrorService.loadState();

      expect(state.vehicles, hasLength(1));
      expect(state.vehicles.first['plate'], 'NGO7290');
      expect(state.vehicles.first.containsKey('latitude'), isFalse);
      expect(state.vehicles.first.containsKey('longitude'), isFalse);
      expect(state.vehicles.first.containsKey('speed'), isFalse);
      expect(state.drivers.single['name'], 'Juan Driver');
      expect(state.trips.map((trip) => trip['tripId']), ['TRP-RECENT']);
      expect(state.dispatchQueue.map((trip) => trip['tripId']), ['TRP-RECENT']);
      expect(state.notifications.single['id'], 'notif-1');
    },
  );

  test('does not mirror live GPS endpoint payloads', () async {
    await LocalFleetMirrorService.mirrorResponse('/fleet/summary/live', {
      'success': true,
      'data': {
        'vehicles': [
          {'plate': 'LIVE-ONLY', 'latitude': 14.2, 'longitude': 121.2},
        ],
      },
    });

    final state = await LocalFleetMirrorService.loadState();

    expect(state.vehicles, isEmpty);
    expect(state.trips, isEmpty);
  });

  test('mirrors dashboard summary and local write queue', () async {
    await LocalFleetMirrorService.mirrorResponse('/fleet/dashboard/summary', {
      'success': true,
      'data': {
        'tripsThisWeek': [
          {'day': 'Mon', 'count': 2},
        ],
        'fleetUtilization': {'rate': 0.64},
      },
    });

    await LocalFleetMirrorService.queueMutation({
      'id': 'mutation-1',
      'type': 'trip.update',
      'method': 'PATCH',
      'path': '/fleet/trips/TRP-1',
      'payload': {'status': 'in transit'},
      'queuedAt': DateTime.now().toIso8601String(),
    });

    final state = await LocalFleetMirrorService.loadState();
    final queue = await LocalFleetMirrorService.loadMutationQueue();

    expect(state.dashboardSummary, isNotNull);
    expect(state.dashboardSummary!['fleetUtilization'], {'rate': 0.64});
    expect(queue, hasLength(1));
    expect(queue.single['type'], 'trip.update');
  });

  test('serializes concurrent mirror writes deterministically', () async {
    final firstWrite = LocalFleetMirrorService.mirrorResponse('/vehicles', {
      'success': true,
      'data': [
        {'plate': 'FIRST', 'truckType': 'Wing Van'},
      ],
    });
    final secondWrite = LocalFleetMirrorService.mirrorResponse('/vehicles', {
      'success': true,
      'data': [
        {'plate': 'SECOND', 'truckType': 'Closed Van'},
      ],
    });

    await Future.wait([firstWrite, secondWrite]);

    final vehicles = await LocalFleetMirrorService.loadCollection(
      LocalFleetMirrorService.vehiclesCollection,
    );

    expect(vehicles, hasLength(1));
    expect(vehicles.single['plate'], 'SECOND');
    expect(vehicles.single['truckType'], 'Closed Van');
  });
}
