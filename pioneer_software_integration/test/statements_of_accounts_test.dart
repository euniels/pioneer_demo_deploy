import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pioneerpath/src/pages/statements_of_accounts.dart';

void main() {
  test(
    'SOA CSV exports invoice columns with numeric PHP values and escaping',
    () {
      final csv = buildStatementCsv([
        {
          'invoiceRows': [
            {
              'invoiceNumber': 'INV-100',
              'issueDate': '2026-05-03T10:00:00+08:00',
              'client': 'Empire Oil, Inc.',
              'tripId': 'TRP-100',
              'erpReference': 'SO-42',
              'poNumber': 'PO-88',
              'drNumber': 'DR-77',
              'subtotalBeforeVat': 'PHP 1,000.00',
              'vatAmount': 'PHP 120.00',
              'totalWithVat': 'PHP 1,120.00',
              'status': 'overdue',
              'daysOverdue': 15,
              'paymentDate': null,
            },
          ],
        },
      ]);

      expect(csv, startsWith('\uFEFF'));
      expect(csv, contains('"Amounts in Philippine Peso (PHP)"'));
      expect(
        csv,
        contains(
          '"Invoice Number","Date","Client","Trip Reference","SO / ERP Reference","PO Number","DR Number","Subtotal","VAT","Total","Status","Days Overdue","Payment Date"',
        ),
      );
      expect(csv, contains('"Empire Oil, Inc."'));
      expect(csv, contains('"SO-42","PO-88","DR-77"'));
      expect(csv, contains('"1000.00","120.00","1120.00"'));
      expect(csv, contains('"Overdue 15 days","15"'));
      expect(csv, isNot(contains('PHP 1,120.00')));
    },
  );

  test('SOA page renders collapsible client statements and payment badges', () {
    final source = File(
      'lib/src/pages/statements_of_accounts.dart',
    ).readAsStringSync();

    expect(source, contains('ExpansionTile'));
    expect(source, contains('Client subtotal'));
    expect(source, contains('Grand total'));
    expect(source, contains('_PaymentStatusBadge'));
    expect(
      source,
      contains("'overdue' => 'Overdue \${_daysOverdue(invoice)} days'"),
    );
    expect(source, contains('All invoice dates'));
    expect(source, contains("label: const Text('Clear')"));
    expect(source, contains('SO / ERP ref'));
    expect(source, contains('_statementEligibleInvoice'));
    expect(source, contains("raw == 'issued'"));
    expect(source, contains("raw == 'paid'"));
  });
}
