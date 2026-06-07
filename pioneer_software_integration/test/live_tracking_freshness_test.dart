import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/live_tracking_freshness.dart';

void main() {
  group('LiveTrackingFreshnessResolver', () {
    test('marks recent vehicle samples as live', () {
      final freshness = LiveTrackingFreshnessResolver.forVehicle({
        'sourceAgeMs': 15000,
        'syncState': 'live',
      });

      expect(freshness.state, LiveTrackingFreshnessState.live);
      expect(freshness.label, 'Live');
      expect(freshness.detail, contains('15s'));
    });

    test('marks recent non-live samples as cached', () {
      final freshness = LiveTrackingFreshnessResolver.forVehicle({
        'sourceAgeMs': 120000,
        'syncState': 'offline_cached',
      });

      expect(freshness.state, LiveTrackingFreshnessState.cached);
      expect(freshness.label, 'Cached');
      expect(freshness.detail, contains('2 min'));
    });

    test('marks old samples as stale', () {
      final freshness = LiveTrackingFreshnessResolver.forVehicle({
        'sourceAgeMs': 360000,
        'syncState': 'live',
      });

      expect(freshness.state, LiveTrackingFreshnessState.stale);
      expect(freshness.label, 'Stale');
      expect(freshness.detail, 'Stale - 6 min ago');
    });

    test('marks unavailable GeoTab feed separately from stale data', () {
      final freshness = LiveTrackingFreshnessResolver.forVehicle({
        'sourceAgeMs': 15000,
        'geotabAvailable': false,
      });

      expect(freshness.state, LiveTrackingFreshnessState.geotabUnavailable);
      expect(freshness.label, 'GeoTab unavailable');
      expect(freshness.detail, 'Feed unavailable');
    });

    test('marks empty fleet state clearly', () {
      final freshness = LiveTrackingFreshnessResolver.forFleet([]);

      expect(freshness.state, LiveTrackingFreshnessState.noVehicles);
      expect(freshness.label, 'No vehicles');
      expect(freshness.detail, 'No vehicles exist in local database');
    });

    test('uses the freshest fleet state when at least one vehicle is live', () {
      final freshness = LiveTrackingFreshnessResolver.forFleet([
        {'sourceAgeMs': 600000},
        {'sourceAgeMs': 20000, 'syncState': 'live'},
      ]);

      expect(freshness.state, LiveTrackingFreshnessState.live);
      expect(freshness.label, 'Live');
    });
  });
}
