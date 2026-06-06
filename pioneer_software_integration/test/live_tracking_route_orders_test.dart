import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/src/pages/live_tracking_page_enhanced.dart',
  ).readAsStringSync();

  test(
    'live tracking subscribes to route-plan trips for order menu updates',
    () {
      expect(source, contains("import '../services/trips_store.dart';"));
      expect(
        source,
        contains('tripsNotifier.addListener(_onRouteOrdersChanged);'),
      );
      expect(
        source,
        contains('tripsNotifier.removeListener(_onRouteOrdersChanged);'),
      );
    },
  );

  test('live tracking exposes GeoTab route orders panel', () {
    expect(source, contains('GeoTab Route Orders'));
    expect(source, contains('_routeOrders'));
    expect(source, contains('geotab_route_plan'));
  });
}
