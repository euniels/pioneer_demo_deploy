import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispatch and trips expose sales to delivery workflow UI', () {
    final dispatch = File(
      'lib/src/pages/dispatch_queue_page.dart',
    ).readAsStringSync();
    final trips = File('lib/src/pages/trips_page.dart').readAsStringSync();

    expect(dispatch, contains('workflowPhaseLabel'));
    expect(dispatch, contains('workflowNextAction'));
    expect(dispatch, contains('Next Phase'));
    expect(dispatch, contains('Pending Assignment'));
    expect(dispatch, contains('Ready to Dispatch'));
    expect(dispatch, contains('In Transit'));
    expect(dispatch, contains('Arrived'));
    expect(dispatch, contains('Order Board'));
    expect(dispatch, contains('Mark Next Phase'));
    expect(dispatch, contains('_buildLiveTransitIndicator'));
    expect(dispatch, contains('Contact Driver'));
    expect(dispatch, contains('FREE DELIVERY CANDIDATE'));
    expect(dispatch, contains("show tripsNotifier"));
    expect(trips, contains('Sales to Delivery Workflow'));
    expect(trips, contains('workflowSteps'));
    expect(trips, contains('fulfillmentLabel'));
    expect(trips, contains('WorkflowTimeline'));
  });
}
