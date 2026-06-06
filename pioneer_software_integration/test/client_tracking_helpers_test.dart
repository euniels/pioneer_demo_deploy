import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/pages/client_tracking_page.dart';
import 'package:pioneerpath/src/theme/app_theme.dart';

void main() {
  test('client tracking ETA reads Arrived for completed trips', () {
    final eta = clientTrackingEtaLabel({
      'status': 'completed',
      'eta': '12 minutes',
    });

    expect(eta, 'Arrived');
  });

  test('client tracking status colors use completed and active states', () {
    expect(clientTrackingStatusColor('completed'), AppTheme.successGreen);
    expect(clientTrackingStatusColor('IN TRANSIT'), AppTheme.primaryBlue);
    expect(
      clientTrackingStatusColor('ARRIVED AT DESTINATION'),
      AppTheme.successGreen,
    );
  });

  test(
    'client tracking headline and public timeline use customer milestones',
    () {
      expect(
        clientTrackingHeadlineStatus({'workflowPhaseNumber': 8}),
        'ORDER DISPATCHED',
      );
      expect(
        clientTrackingHeadlineStatus({'workflowPhaseNumber': 10}),
        'IN TRANSIT',
      );
      expect(
        clientTrackingHeadlineStatus({'workflowPhaseNumber': 11}),
        'ARRIVED AT DESTINATION',
      );
      expect(
        clientTrackingHeadlineStatus({'workflowPhaseNumber': 12}),
        'DELIVERED',
      );
      expect(
        clientTrackingHeadlineStatus({'status': 'dispatched'}),
        'IN TRANSIT',
      );
      expect(clientTrackingPublicTimelineIndex({'workflowPhaseNumber': 10}), 2);
      expect(clientTrackingPublicTimelineIndex({'status': 'dispatched'}), 2);
    },
  );

  test('client tracking formats Distance Matrix ETA for the client', () {
    expect(
      clientTrackingArrivalLabel({
        'status': 'dispatched',
        'workflowPhaseNumber': 10,
        'eta': '2 hours 15 min',
        'etaSource': 'google_distance_matrix',
        'etaDurationSeconds': 8100,
      }),
      'Arriving in 2 hours 15 min',
    );
  });

  test(
    'client tracking workflow text maps internal phases to client language',
    () {
      expect(
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 5}),
        'Your order is being prepared',
      );
      expect(
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 8}),
        'Your delivery is being arranged',
      );
      expect(
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 10}),
        'Your delivery is on its way',
      );
      expect(
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 11}),
        'Your delivery has arrived',
      );
      expect(
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 12}),
        'Delivery complete',
      );
    },
  );

  test('client page presents privacy-safe delivery and POD information', () {
    final source = File(
      'lib/src/pages/client_tracking_page.dart',
    ).readAsStringSync();

    expect(source, contains('driverContactMasked'));
    expect(source, contains('Contact through Pioneer dispatch'));
    expect(source, contains('Vehicle plate'));
    expect(source, contains('Proof of delivery'));
    expect(source, contains('Awaiting delivery'));
    expect(source, contains('Delivery journey'));
    expect(source, contains('Order Received'));
    expect(source, contains('In Transit'));
    expect(source, contains('Delivered'));
    expect(source, isNot(contains("data['orderValue']")));
  });
}
