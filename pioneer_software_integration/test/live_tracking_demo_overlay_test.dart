import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/vehicles_store.dart';

void main() {
  tearDown(() {
    vehiclesNotifier.value = const [];
  });

  test('fleet live payload keeps real vehicles and appends demo map vehicles', () {
    final vehicles = applyFleetLivePayload({
      'vehicles': [
        {
          'id': 'real-device-001',
          'geotabId': 'real-device-001',
          'plate': 'REAL-TRK-01',
          'latitude': 14.58,
          'longitude': 121.02,
          'speed': 24,
          'bearing': 90,
          'isDriving': true,
          'ignitionOn': true,
          'isCommunicating': true,
        },
      ],
    });

    final plates = vehicles.map((vehicle) => vehicle['plate']).toSet();

    expect(plates, contains('REAL-TRK-01'));
    expect(plates, contains('DEMO-TRK-01'));
    expect(plates, contains('DEMO-TRK-02'));
    expect(plates, contains('DEMO-TRK-03'));
  });

  test('demo overlay does not duplicate a real vehicle using a demo plate', () {
    final vehicles = applyFleetLivePayload({
      'vehicles': [
        {
          'id': 'real-device-demo-plate',
          'geotabId': 'real-device-demo-plate',
          'plate': 'DEMO-TRK-01',
          'latitude': 14.58,
          'longitude': 121.02,
          'speed': 12,
          'bearing': 45,
          'isDriving': true,
          'ignitionOn': true,
          'isCommunicating': true,
        },
      ],
    });

    final demoOneCount = vehicles
        .where((vehicle) => vehicle['plate'] == 'DEMO-TRK-01')
        .length;

    expect(demoOneCount, 1);
  });

  test('fleet summary vehicle lists can also preserve demo map vehicles', () {
    final vehicles = includeDemoLiveVehicles([
      {
        'id': 'summary-real-device-001',
        'plate': 'REAL-SUMMARY-01',
        'latitude': 14.55,
        'longitude': 121.01,
      },
    ]);

    final plates = vehicles.map((vehicle) => vehicle['plate']).toSet();

    expect(plates, contains('REAL-SUMMARY-01'));
    expect(plates, contains('DEMO-TRK-01'));
    expect(plates, contains('DEMO-TRK-02'));
    expect(plates, contains('DEMO-TRK-03'));
  });
}
