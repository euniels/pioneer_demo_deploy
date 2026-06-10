import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispatch and trips expose delivery trip workflow UI', () {
    final dispatch = File(
      'lib/src/pages/dispatch_queue_page.dart',
    ).readAsStringSync();
    final trips = File('lib/src/pages/trips_page.dart').readAsStringSync();

    expect(dispatch, contains('workflowPhaseLabel'));
    expect(dispatch, contains('workflowNextAction'));
    expect(dispatch, contains('Next Phase'));
    expect(dispatch, contains('Pending Details'));
    expect(dispatch, contains('Pending Assignment'));
    expect(dispatch, contains('In Transit'));
    expect(dispatch, contains('Arrived'));
    expect(dispatch, contains('Pending POD'));
    expect(dispatch, contains('Billing Review'));
    expect(dispatch, contains('Order Board'));
    expect(dispatch, contains('Mark Next Phase'));
    expect(dispatch, contains('_buildLiveTransitIndicator'));
    expect(dispatch, contains('Contact Driver'));
    expect(dispatch, contains('FREE DELIVERY CANDIDATE'));
    expect(dispatch, contains("show tripsNotifier"));
    expect(trips, contains('Delivery Trip Workflow'));
    expect(trips, contains('workflowSteps'));
    expect(trips, contains('fulfillmentLabel'));
    expect(trips, contains('WorkflowTimeline'));
    expect(dispatch, isNot(contains('Inquiry & quotation')));
    expect(dispatch, isNot(contains('Fulfillment strategy')));
    expect(trips, isNot(contains('Sales to Delivery Workflow')));
  });
}
