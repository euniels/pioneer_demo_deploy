import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/services/geotab_sync_status_service.dart';
import 'package:pioneerpath/src/widgets/geotab_sync_status_badge.dart';
import 'package:pioneerpath/src/widgets/geotab_push_preview.dart';

void main() {
  test('settings exposes geotab writeback approval center', () {
    final source = File('lib/src/pages/settings_page.dart').readAsStringSync();

    expect(source, contains('GeoTab Write-Back Approval'));
    expect(source, contains('approveGeotabWriteBackJob'));
    expect(source, contains('Temporary MyGeotab Password'));
    expect(source, contains('GeoTab Route Push Flow'));
    expect(source, contains('preview-first write-back workflow'));
    expect(source, contains('GeotabPushPreviewContent'));
    expect(source, contains('previewGroups'));
    expect(source, contains('requiresTemporaryPassword'));
    expect(source, contains('Required rejection reason'));
    expect(source, contains('Delete this pending job?'));
    expect(source, contains('_writeBackExpandedPreference'));
    expect(source, contains('GeoTab Company Group ID'));
    expect(
      source,
      contains(
        'Zone push requires GeoTab Company Group ID to be configured in Settings -> Map Settings before zones can be pushed.',
      ),
    );
    expect(source, contains('Rejection reason: \$error'));
  });

  test('fleet data coordinator provides cache-first startup entry point', () {
    final source = File(
      'lib/src/services/fleet_data_coordinator.dart',
    ).readAsStringSync();

    expect(source, contains('BackendApiService.bootstrapOfflineSupport'));
    expect(source, contains('warmFleetStateFromCache'));
    expect(source, contains('refreshSilently'));
  });

  test('backend api exposes writeback endpoints', () {
    final source = File('lib/src/services/backend_api.dart').readAsStringSync();

    expect(source, contains('/fleet/geotab/writeback/jobs'));
    expect(source, contains('/fleet/routes/\$routeId/push-geotab'));
    expect(source, isNot(contains('/fleet/geotab/routes')));
    expect(source, isNot(contains('/assign-device')));
    expect(source, contains("'reason': reason"));
    expect(source, contains('deleteGeotabWriteBackJob'));
  });

  test('geotab sync visual maps statuses to production labels', () {
    expect(geoTabSyncVisual('not_staged').label, 'GeoTab: Never synced');
    expect(geoTabSyncVisual('synced').label, 'GeoTab: Up to date');
    expect(
      geoTabSyncVisual('local_modified').label,
      'GeoTab: Local changes pending',
    );
    expect(
      geoTabSyncVisual('pending_approval').label,
      'GeoTab: Push awaiting approval',
    );
    expect(
      geoTabSyncVisual('approved').label,
      'GeoTab: Push approved, executing',
    );
    expect(geoTabSyncVisual('failed').canPush, isTrue);
    expect(
      geoTabSyncVisual('permanently_failed').label,
      'GeoTab: Permanently failed',
    );
  });

  test('geotab sync badges are present on managed entity list rows', () {
    final pageSources = <String, String>{
      'vehicles': File('lib/src/pages/vehicles_page.dart').readAsStringSync(),
      'drivers': File('lib/src/pages/drivers_page.dart').readAsStringSync(),
      'routes': File('lib/src/pages/routes_page.dart').readAsStringSync(),
      'zones': File('lib/src/pages/zones_page.dart').readAsStringSync(),
      'maintenance': File(
        'lib/src/pages/maintenance_page.dart',
      ).readAsStringSync(),
    };

    for (final entry in pageSources.entries) {
      expect(
        entry.value,
        contains('GeoTabSyncStatusBadge.fromEntity'),
        reason: '${entry.key} list rows must show GeoTab sync status.',
      );
      expect(
        entry.value,
        contains('compact: true'),
        reason: '${entry.key} list rows should use the compact badge.',
      );
    }
  });

  testWidgets('geotab sync status badge renders understandable label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GeoTabSyncStatusBadge.fromEntity(const {
            'syncStatus': 'local_modified',
          }),
        ),
      ),
    );

    expect(find.text('GeoTab: Local changes pending'), findsOneWidget);
  });

  testWidgets('geotab push guard blocks unchanged data with clear toast', (
    tester,
  ) async {
    var allowed = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                allowed = await guardGeotabPushPreview(
                  context: context,
                  preview: const {'geotabAlreadyUpToDate': true},
                );
              },
              child: const Text('Guard'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Guard'));
    await tester.pump();

    expect(allowed, isFalse);
    expect(find.text(noGeotabChangesMessage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('geotab push guard warns before duplicate pending push', (
    tester,
  ) async {
    var allowed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                allowed = await guardGeotabPushPreview(
                  context: context,
                  preview: const {
                    'hasPendingGeotabPush': true,
                    'pendingGeotabPush': {'status': 'pending_approval'},
                  },
                );
              },
              child: const Text('Guard'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Guard'));
    await tester.pumpAndSettle();

    expect(find.text('Push already waiting'), findsOneWidget);
    await tester.tap(find.text('Submit Anyway'));
    await tester.pumpAndSettle();

    expect(allowed, isTrue);
  });

  testWidgets('geotab push preview shows first push fields as not in geotab', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GeotabPushPreviewContent(
            entityType: 'Driver',
            entityName: 'Juan Driver',
            payload: {'name': 'Juan Driver', 'licenseNumber': 'N01-23-456789'},
            snapshot: null,
          ),
        ),
      ),
    );

    expect(
      find.text(
        'New - does not exist in GeoTab yet. All payload fields below will be created.',
      ),
      findsOneWidget,
    );
    expect(find.text('Not in GeoTab'), findsWidgets);
    expect(find.text('licenseNumber'), findsOneWidget);
  });

  testWidgets('geotab push preview only shows changed payload fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GeotabPushPreviewContent(
            entityType: 'Vehicle',
            entityName: 'ABC 123',
            payload: {
              'name': 'ABC 123',
              'comment': 'New local note',
              'unchanged': 'same',
            },
            snapshot: {
              'name': 'ABC 123',
              'comment': 'Old GeoTab note',
              'unchanged': 'same',
            },
          ),
        ),
      ),
    );

    expect(find.text('comment'), findsOneWidget);
    expect(find.text('Old GeoTab note'), findsOneWidget);
    expect(find.text('New local note'), findsOneWidget);
    expect(find.text('unchanged'), findsNothing);
  });

  testWidgets('geotab push preview shows grouped driver vehicle changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GeotabPushPreviewContent(
            entityType: 'Grouped GeoTab Push',
            entityName: 'Juan Driver + ABC 123',
            payload: {
              'groupType': 'driver_vehicle_assignment',
              'operations': [],
            },
            snapshot: {},
            previewGroups: [
              {
                'entityType': 'Driver',
                'entityName': 'Juan Driver',
                'isFirstPush': false,
                'rows': [
                  {
                    'field': 'entity.name',
                    'before': 'Juan Old',
                    'after': 'Juan Driver',
                  },
                ],
              },
              {
                'entityType': 'Vehicle',
                'entityName': 'ABC 123',
                'isFirstPush': false,
                'rows': [
                  {
                    'field': 'entity.licensePlate',
                    'before': 'OLD 123',
                    'after': 'ABC 123',
                  },
                ],
              },
            ],
          ),
        ),
      ),
    );

    expect(find.text('Driver: Juan Driver'), findsOneWidget);
    expect(find.text('Vehicle: ABC 123'), findsOneWidget);
    expect(find.text('Juan Old'), findsOneWidget);
    expect(find.text('ABC 123'), findsWidgets);
  });
}
