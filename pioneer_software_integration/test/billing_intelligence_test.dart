import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('billing page exposes policy and POD readiness UI', () {
    final source = File('lib/src/pages/billing_page.dart').readAsStringSync();

    expect(source, contains('POD GATE'));
    expect(source, contains('Operational Assurance'));
    expect(source, contains('collectionReadiness'));
    expect(source, contains('billingDecision'));
  });

  test('billing page exposes finance KPI table and receipt controls', () {
    final source = File('lib/src/pages/billing_page.dart').readAsStringSync();

    expect(source, contains('Total Invoiced This Month'));
    expect(source, contains('Total Collected This Month'));
    expect(source, contains('Outstanding Balance'));
    expect(source, contains('Overdue Amount'));
    expect(source, contains("_InvoiceTableHeader('INVOICE NO.')"));
    expect(source, contains('VAT'));
    expect(source, contains('Line Items'));
    expect(source, contains('ERP Reference Details'));
    expect(source, contains('Mark Paid'));
    expect(source, contains("label: const Text('Print')"));
    expect(source, contains("return '₱"));
  });

  test(
    'billing page exposes CRUD lifecycle controls for trip-linked invoices',
    () {
      final source = File('lib/src/pages/billing_page.dart').readAsStringSync();

      expect(source, contains('New Manual Invoice'));
      expect(source, contains('Linked trip'));
      expect(source, contains('Required override reason'));
      expect(source, contains('Approve invoice'));
      expect(source, contains('Reject invoice'));
      expect(source, contains('Issue invoice'));
      expect(source, contains('Payment reference'));
      expect(source, contains('Final charge basis'));
      expect(source, contains('Approval note'));
      expect(source, contains('Rejection reason'));
      expect(source, contains('Mark Paid'));
      expect(source, contains('Mark Overdue'));
      expect(source, contains('Void invoice'));
      expect(source, contains('Lifecycle Audit'));
    },
  );
}
