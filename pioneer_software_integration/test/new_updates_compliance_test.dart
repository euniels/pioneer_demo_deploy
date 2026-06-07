import 'dart:io';

import 'package:flutter/material.dart' show Color, MaterialApp, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/pages/notification_page.dart';
import 'package:pioneerpath/src/pages/trips_page.dart';
import 'package:pioneerpath/src/services/google_map_marker_factory.dart';
import 'package:pioneerpath/src/services/notification_service.dart';

void main() {
  test('live tracking marker factory exposes exact requested marker sizes', () {
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.moving,
      ),
      86,
    );
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.idle,
      ),
      72,
    );
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.offline,
      ),
      58,
    );
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.stale,
      ),
      62,
    );
  });

  test('selected live tracking markers stay visibly larger on Google Maps', () {
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.moving,
        selected: true,
      ),
      greaterThan(
        PioneerGoogleMapMarkerFactory.markerLogicalSize(
          PioneerMapMarkerStyle.moving,
        ),
      ),
    );
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.idle,
        selected: true,
      ),
      greaterThan(
        PioneerGoogleMapMarkerFactory.markerLogicalSize(
          PioneerMapMarkerStyle.idle,
        ),
      ),
    );
  });

  test('regional zoom markers use fixed compact screen-space descriptors', () {
    for (final style in PioneerMapMarkerStyle.values) {
      expect(
        PioneerGoogleMapMarkerFactory.markerLogicalSize(style, compact: true),
        lessThan(PioneerGoogleMapMarkerFactory.markerLogicalSize(style)),
      );
    }
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.moving,
        compact: true,
      ),
      38,
    );
    expect(
      PioneerGoogleMapMarkerFactory.markerLogicalSize(
        PioneerMapMarkerStyle.stale,
        compact: true,
      ),
      31,
    );
  });

  test(
    'live tracking swaps compact markers and state-accented vehicle cards',
    () {
      final source = File(
        'lib/src/pages/live_tracking_page_enhanced.dart',
      ).readAsStringSync();

      expect(source, contains('_compactMarkerZoomThreshold = 12.0'));
      expect(source, contains('compact: _usesCompactMapMarkers'));
      expect(source, contains('_sidebarStateAccent'));
      expect(source, contains('LiveTrackingFreshnessResolver.forVehicle'));
      expect(source, contains('fleetFreshness'));
      expect(source, contains('_buildFreshnessPill'));
      expect(source, contains('AppTheme.successGreen'));
      expect(source, contains('AppTheme.errorRed'));
      expect(source, contains('_statusLabel(vehicle)'));
      expect(source, contains('Unknown plate'));
      expect(source, contains('Location unavailable'));
      expect(source, contains('if (mounted && _vehicleMarkers.isNotEmpty)'));
    },
  );

  test('live tracking marker colors match PioneerPath compliance spec', () {
    expect(
      PioneerGoogleMapMarkerFactory.markerFillColor(
        PioneerMapMarkerStyle.moving,
      ),
      const Color(0xFF1A3A6B),
    );
    expect(
      PioneerGoogleMapMarkerFactory.markerFillColor(PioneerMapMarkerStyle.idle),
      const Color(0xFFFF9F43),
    );
    expect(
      PioneerGoogleMapMarkerFactory.markerFillColor(
        PioneerMapMarkerStyle.offline,
      ),
      const Color(0xFF4B5563),
    );
  });

  test('trip map insufficient route wording matches compliance copy', () {
    expect(
      tripMapInsufficientPointsMessage,
      'Route data unavailable - insufficient GPS points',
    );
  });

  test('notifications expose the required primary tabs in order', () {
    expect(notificationPrimaryTabLabels, ['All', 'Unread', 'Alerts', 'System']);
  });

  test(
    'notification inbox uses one card source with responsive dismiss UI',
    () {
      final source = File(
        'lib/src/pages/notification_page.dart',
      ).readAsStringSync();

      expect(source, contains('NotificationService.instance'));
      expect(source, contains('_svc.notifications.value'));
      expect(source, contains('_NotificationTile'));
      expect(source, contains('Dismissible'));
      expect(source, contains('Dismiss notification'));
      expect(source, contains('AppTheme.colorFFEBF5FB'));
      expect(source, contains('AppTheme.successGreen'));
    },
  );

  testWidgets('notification page paints the same four unread inbox records', (
    tester,
  ) async {
    final service = NotificationService.instance;
    service.replaceNotifications(
      List.generate(
        4,
        (index) => NotificationItem(
          id: 'page-card-$index',
          title: 'Unread Notice ${index + 1}',
          message: 'Stored operational update ${index + 1}.',
          time: 'Now',
          timestamp: DateTime(2026, 5, 24, 9, index),
          category: NotificationCategory.system,
        ),
      ),
    );
    addTearDown(service.deleteAll);
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: NotificationsPage()));
    await tester.pump();

    expect(find.text('4 unread'), findsOneWidget);
    for (var index = 1; index <= 4; index++) {
      expect(find.text('Unread Notice $index'), findsOneWidget);
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
  });
}
