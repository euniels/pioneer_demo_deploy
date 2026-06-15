import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/backend_api.dart';

void main() {
  test('offline demo mode is wired through BackendApiService', () {
    final backendApi = File(
      'lib/src/services/backend_api.dart',
    ).readAsStringSync();
    final offlineDemo = File(
      'lib/src/services/offline_demo_backend.dart',
    ).readAsStringSync();

    expect(backendApi, contains("import 'offline_demo_backend.dart';"));
    expect(backendApi, contains('static bool get isOfflineDemo'));
    expect(backendApi, contains('OfflineDemoBackend.decodedResponse(path)'));
    expect(backendApi, contains('OfflineDemoBackend.mutate(method, path'));
    expect(offlineDemo, contains("bool.fromEnvironment(\n    'OFFLINE_DEMO'"));
    expect(offlineDemo, contains('DEMO-TRK-01'));
    expect(offlineDemo, contains('DEMO-TRIP-BILLED'));
    expect(offlineDemo, contains('INV-DEMO-001'));
  });

  test('offline demo API returns UI-ready payloads when enabled', () async {
    if (!BackendApiService.isOfflineDemo) {
      return;
    }

    final login = await BackendApiService.loginManagedUser(
      'admin@pioneerpath.local',
      'Pioneer@12345',
    );
    final summary = await BackendApiService.getFleetSummary(forceRefresh: true);
    final billing = await BackendApiService.getBillingInvoices(
      forceRefresh: true,
    );

    expect(login['auth'], isA<Map>());
    expect(summary['vehicles'], isA<List>());
    expect(summary['trips'], isA<List>());
    expect(billing['invoices'], isA<List>());
  });
}
