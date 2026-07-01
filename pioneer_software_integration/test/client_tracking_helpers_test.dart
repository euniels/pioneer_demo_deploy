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

  test('client tracking status colors use canonical workflow states', () {
    expect(clientTrackingStatusColor('completed'), AppTheme.successGreen);
    expect(clientTrackingStatusColor('IN TRANSIT'), AppTheme.colorFF14B8A6);
    expect(
      clientTrackingStatusColor('ARRIVED AT DESTINATION'),
      AppTheme.colorFFF59E0B,
    );
  });

  test(
    'client tracking headline and public timeline use customer milestones',
    () {
      expect(
        clientTrackingHeadlineStatus({'workflowPhaseNumber': 2}),
        'DELIVERY REQUESTED',
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
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 2}),
        'Your delivery request is being prepared',
      );
      expect(
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 5}),
        'Your delivery is being assigned',
      );
      expect(
        clientTrackingWorkflowStatus({'workflowPhaseNumber': 7}),
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

    expect(source, isNot(contains('driverContactMasked')));
    expect(source, isNot(contains("label: 'Driver'")));
    expect(source, contains('Vehicle plate'));
    expect(source, contains('Cargo condition'));
    expect(source, contains('Billing status'));
    expect(source, contains("data['invoiceSummary']"));
    expect(source, contains('POD condition summary'));
    expect(source, contains('Proof of delivery'));
    expect(source, contains('Awaiting delivery'));
    expect(source, contains('Delivery journey'));
    expect(source, contains('Trip Requested'));
    expect(source, contains('In Transit'));
    expect(source, contains('Delivered'));
    expect(source, isNot(contains("data['orderValue']")));
    expect(source, isNot(contains("data['fuelCost']")));
    expect(source, isNot(contains("data['tollFees']")));
  });
}
