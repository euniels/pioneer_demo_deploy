import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BackendApiService respects 429 retry windows', () {
    final source = File('lib/src/services/backend_api.dart').readAsStringSync();

    expect(source, contains('statusCode: 429'));
    expect(source, contains('retryAfter'));
    expect(source, contains('_pausedUntil'));
    expect(source, contains('_pausePathFromResponse'));
    expect(source, contains("response.headers['retry-after']"));
  });

  test('startup warm queue avoids heavy module burst requests', () {
    final source = File(
      'lib/src/services/fleet_data_coordinator.dart',
    ).readAsStringSync();
    final queueStart = source.indexOf('static Future<void> _runPriorityQueue');
    final queueEnd = source.indexOf('static Future<void> _runTier');
    final queueBody = source.substring(queueStart, queueEnd);

    expect(queueBody, contains('/fleet/summary/live'));
    expect(queueBody, contains('/fleet/summary'));
    expect(queueBody, contains('/fleet/dashboard/summary'));
    expect(queueBody, contains('/fleet/summary/analytics'));
    expect(queueBody, isNot(contains('/billing/invoices')));
    expect(queueBody, isNot(contains('/billing/soa')));
    expect(queueBody, isNot(contains('/fleet/maintenance')));
    expect(queueBody, isNot(contains('/fleet/routes')));
    expect(queueBody, isNot(contains('/fleet/notifications')));
    expect(queueBody, isNot(contains('/fleet/geotab/writeback/jobs')));
  });

  test('live tracking skips overlapping poll refreshes', () {
    final source = File(
      'lib/src/pages/live_tracking_page_enhanced.dart',
    ).readAsStringSync();

    expect(source, contains('bool _isLoadingVehicles = false'));
    expect(source, contains('if (_isLoadingVehicles)'));
    expect(source, contains('_isLoadingVehicles = true'));
    expect(source, contains('_isLoadingVehicles = false'));
  });
}
