import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/utils/dispatch_workflow_policy.dart';

void main() {
  test('dispatch workflow phase groups match shared policy', () {
    expect(DispatchWorkflowPolicy.groupForPhase(2), 'Pending Details');
    expect(DispatchWorkflowPolicy.groupForPhase(6), 'Pending Assignment');
    expect(DispatchWorkflowPolicy.groupForPhase(9), 'Ready to Dispatch');
    expect(DispatchWorkflowPolicy.groupForPhase(10), 'In Transit');
    expect(DispatchWorkflowPolicy.groupForPhase(11), 'Arrived / POD Needed');
    expect(
      DispatchWorkflowPolicy.groupForPhase(12),
      'Completed / POD Review Handoff',
    );
  });

  test('dispatch workflow blocks POD handoff from dispatch queue', () {
    expect(
      DispatchWorkflowPolicy.blockedReason({
        'workflowPhaseNumber': 11,
        'status': 'dispatched',
        'driver': 'Driver',
        'vehicle': 'TRK-01',
      }),
      contains('POD/admin review'),
    );
    expect(
      DispatchWorkflowPolicy.blockedReason({
        'workflowPhaseNumber': 9,
        'status': 'pending',
        'driver': '',
        'vehicle': 'TRK-01',
      }),
      contains('driver'),
    );
    expect(
      DispatchWorkflowPolicy.nextDispatchUpdates({
        'workflowPhaseNumber': 10,
        'status': 'dispatched',
      })['workflowPhaseNumber'],
      11,
    );
  });
}
