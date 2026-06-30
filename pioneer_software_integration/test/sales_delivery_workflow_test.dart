import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispatch and trips expose delivery trip workflow UI', () {
    final dispatch = File(
      'lib/src/pages/dispatch_queue_page.dart',
    ).readAsStringSync();
    final trips = File('lib/src/pages/trips_page.dart').readAsStringSync();
    final workflowPolicy = File(
      'lib/src/utils/dispatch_workflow_policy.dart',
    ).readAsStringSync();

    expect(dispatch, contains('workflowPhaseLabel'));
    expect(dispatch, contains('workflowNextAction'));
    expect(dispatch, contains('Pending Details'));
    expect(dispatch, contains('Pending Assignment'));
    expect(dispatch, contains('Ready to Dispatch'));
    expect(dispatch, contains('In Transit'));
    expect(dispatch, contains('Arrived / POD Needed'));
    expect(dispatch, contains('Completed / POD Review Handoff'));
    expect(dispatch, contains('Order Board'));
    expect(dispatch, contains('DispatchWorkflowPolicy'));
    expect(workflowPolicy, contains('Continue Setup'));
    expect(workflowPolicy, contains('Start Dispatch'));
    expect(workflowPolicy, contains('Mark Arrived'));
    expect(workflowPolicy, contains('Waiting for POD'));
    expect(dispatch, contains('_buildLiveTransitIndicator'));
    expect(dispatch, contains('Contact Driver'));
    expect(dispatch, contains('FREE DELIVERY CANDIDATE'));
    expect(dispatch, contains("show tripsNotifier"));
    expect(trips, contains('Delivery Trip Workflow'));
    expect(trips, contains('workflowSteps'));
    expect(trips, contains('fulfillmentLabel'));
    expect(trips, contains('WorkflowTimeline'));
    expect(trips, contains('Billing Readiness'));
    expect(trips, contains('getTripBillingPreview'));
    expect(trips, contains('Submit for Review'));
    expect(dispatch, isNot(contains('Inquiry & quotation')));
    expect(dispatch, isNot(contains('Fulfillment strategy')));
    expect(trips, isNot(contains('Sales to Delivery Workflow')));
    expect(trips, isNot(contains('Complete and Bill')));
    expect(trips, isNot(contains('addBilling(')));
  });
}
