// lib/src/services/billing_store.dart
import 'package:flutter/material.dart';

import 'notification_service.dart';

final ValueNotifier<List<Map<String, dynamic>>> billingsNotifier =
    ValueNotifier<List<Map<String, dynamic>>>(_initialBillings());

List<Map<String, dynamic>> _initialBillings() => [];

void addBilling(Map<String, dynamic> billing) {
  billingsNotifier.value = [billing, ...billingsNotifier.value];
  final svc = NotificationService.instance;
  svc.addNotification(
    NotificationItem(
      id: svc.nextId(),
      title: 'Invoice Created - ${billing['invoiceNumber'] ?? billing['id']}',
      message:
          'Invoice for ${billing['client']} (${billing['amount']}) has been generated for trip ${billing['tripId']}.',
      time: 'Just now',
      timestamp: DateTime.now(),
      category: NotificationCategory.billing,
      isRead: false,
    ),
  );
}

void updateBilling(String invoiceId, Map<String, dynamic> updates) {
  billingsNotifier.value = billingsNotifier.value.map((billing) {
    if (billing['id'] == invoiceId) {
      return {...billing, ...updates};
    }
    return billing;
  }).toList();
}

void setBillingDueDate(String invoiceId, DateTime dueDate) {
  final isOverdue = DateTime.now().isAfter(dueDate);
  updateBilling(invoiceId, {
    'dueDate': dueDate.toString().split(' ')[0],
    'status': isOverdue ? 'overdue' : 'sent',
  });
}

void markBillingAsPaid(String invoiceId) {
  final billing = billingsNotifier.value.firstWhere(
    (b) => b['id'] == invoiceId,
    orElse: () => <String, dynamic>{},
  );
  updateBilling(invoiceId, {'status': 'paid'});
  if (billing.isNotEmpty) {
    final svc = NotificationService.instance;
    svc.addNotification(
      NotificationItem(
        id: svc.nextId(),
        title: 'Payment Received - $invoiceId',
        message:
            '${billing['client']} paid ${billing['amount']} for invoice $invoiceId. Status updated to Paid.',
        time: 'Just now',
        timestamp: DateTime.now(),
        category: NotificationCategory.billing,
        isRead: false,
      ),
    );
  }
}

bool isBillingOverdue(Map<String, dynamic> billing) {
  if (billing['status'] != 'sent') {
    return false;
  }
  final dueDate = billing['dueDate'];
  if (dueDate == null) {
    return false;
  }

  final due = DateTime.parse(dueDate);
  return DateTime.now().isAfter(due);
}

int getDaysUntilDue(Map<String, dynamic> billing) {
  final dueDate = billing['dueDate'];
  if (dueDate == null) {
    return 0;
  }

  final due = DateTime.parse(dueDate);
  return due.difference(DateTime.now()).inDays;
}
