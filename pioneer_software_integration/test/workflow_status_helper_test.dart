import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/utils/workflow_status_helper.dart';

void main() {
  test('trip statuses use canonical delivery workflow labels', () {
    expect(WorkflowStatusHelper.trip('pending').label, 'Pending');
    expect(WorkflowStatusHelper.trip('ready').label, 'Ready to Dispatch');
    expect(WorkflowStatusHelper.trip('dispatched').label, 'Dispatched');
    expect(WorkflowStatusHelper.trip('active').label, 'In Transit');
    expect(WorkflowStatusHelper.trip('arrived').label, 'Arrived');
    expect(WorkflowStatusHelper.trip('pending_approval').label, 'Pending POD');
    expect(WorkflowStatusHelper.trip('completed').label, 'Completed');
    expect(WorkflowStatusHelper.trip('ready_to_bill').label, 'Ready to Bill');
    expect(WorkflowStatusHelper.trip('invoiced').label, 'Invoiced');
    expect(WorkflowStatusHelper.trip('paid').label, 'Paid');
    expect(WorkflowStatusHelper.trip('voided').strikethrough, isTrue);
    expect(WorkflowStatusHelper.trip('cancelled').label, 'Cancelled');
  });

  test('invoice statuses use the same financial lifecycle labels', () {
    expect(WorkflowStatusHelper.invoice('draft').label, 'Draft');
    expect(WorkflowStatusHelper.invoice('approved').label, 'Approved');
    expect(WorkflowStatusHelper.invoice('rejected').label, 'Rejected');
    expect(WorkflowStatusHelper.invoice('issued').label, 'Issued');
    expect(WorkflowStatusHelper.invoice('sent').label, 'Issued');
    expect(WorkflowStatusHelper.invoice('partial').label, 'Partial');
    expect(WorkflowStatusHelper.invoice('paid').label, 'Paid');
    expect(WorkflowStatusHelper.invoice('overdue').label, 'Overdue');
    expect(WorkflowStatusHelper.invoice('voided').strikethrough, isTrue);
  });

  test('workflow pages consume the shared status helper', () {
    final files = [
      'lib/src/pages/trips_page.dart',
      'lib/src/pages/dispatch_queue_page.dart',
      'lib/src/pages/billing_page.dart',
      'lib/src/pages/client_tracking_page.dart',
      'lib/src/pages/statements_of_accounts.dart',
    ];

    for (final file in files) {
      expect(
        File(file).readAsStringSync(),
        contains('WorkflowStatusHelper'),
        reason: '$file should use the shared workflow status helper.',
      );
    }
  });

  test('disabled workflow action reasons are specific', () {
    expect(
      WorkflowStatusHelper.disabledActionReason(
        action: 'dispatch',
        status: 'pending',
        hasDriver: false,
      ),
      'Cannot dispatch - no driver assigned',
    );
    expect(
      WorkflowStatusHelper.disabledActionReason(
        action: 'invoice',
        status: 'completed',
        hasPod: false,
      ),
      'Cannot invoice - POD not confirmed',
    );
    expect(
      WorkflowStatusHelper.disabledActionReason(
        action: 'void',
        isPaid: true,
      ),
      'Cannot void - invoice already paid',
    );
  });
}
