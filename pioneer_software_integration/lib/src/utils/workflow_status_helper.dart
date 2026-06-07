import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class WorkflowStatusPresentation {
  const WorkflowStatusPresentation({
    required this.key,
    required this.label,
    required this.color,
    required this.icon,
    this.strikethrough = false,
  });

  final String key;
  final String label;
  final Color color;
  final IconData icon;
  final bool strikethrough;
}

class WorkflowStatusHelper {
  const WorkflowStatusHelper._();

  static WorkflowStatusPresentation trip(dynamic status) {
    final normalized = _normalize(status);

    if (normalized.contains('cancel')) {
      return const WorkflowStatusPresentation(
        key: 'cancelled',
        label: 'Cancelled',
        color: AppTheme.errorRed,
        icon: Icons.cancel_outlined,
      );
    }
    if (normalized.contains('void')) {
      return const WorkflowStatusPresentation(
        key: 'voided',
        label: 'Voided',
        color: AppTheme.neutralGray,
        icon: Icons.block,
        strikethrough: true,
      );
    }
    if (normalized.contains('paid') || normalized.contains('collected')) {
      return const WorkflowStatusPresentation(
        key: 'paid',
        label: 'Paid',
        color: Color(0xFF065F46),
        icon: Icons.payments_outlined,
      );
    }
    if (normalized.contains('invoice')) {
      return const WorkflowStatusPresentation(
        key: 'invoiced',
        label: 'Invoiced',
        color: AppTheme.successGreen,
        icon: Icons.receipt_long_outlined,
      );
    }
    if (normalized.contains('ready') && normalized.contains('bill')) {
      return const WorkflowStatusPresentation(
        key: 'ready_to_bill',
        label: 'Ready to Bill',
        color: AppTheme.successGreen,
        icon: Icons.fact_check_outlined,
      );
    }
    if (normalized.contains('pod')) {
      return const WorkflowStatusPresentation(
        key: 'pending_pod',
        label: 'Pending POD',
        color: AppTheme.warningOrange,
        icon: Icons.assignment_late_outlined,
      );
    }
    if (normalized.contains('approval')) {
      return const WorkflowStatusPresentation(
        key: 'pending_pod',
        label: 'Pending POD',
        color: AppTheme.warningOrange,
        icon: Icons.assignment_late_outlined,
      );
    }
    if (normalized.contains('complete') ||
        normalized.contains('delivered') ||
        normalized.contains('done')) {
      return const WorkflowStatusPresentation(
        key: 'completed',
        label: 'Completed',
        color: AppTheme.successGreen,
        icon: Icons.check_circle_outline,
      );
    }
    if (normalized.contains('arriv')) {
      return const WorkflowStatusPresentation(
        key: 'arrived',
        label: 'Arrived',
        color: AppTheme.colorFFF59E0B,
        icon: Icons.flag_outlined,
      );
    }
    if (normalized.contains('transit') ||
        normalized.contains('progress') ||
        normalized.contains('on trip') ||
        normalized.contains('active')) {
      return const WorkflowStatusPresentation(
        key: 'in_transit',
        label: 'In Transit',
        color: AppTheme.colorFF14B8A6,
        icon: Icons.local_shipping_outlined,
      );
    }
    if (normalized.contains('dispatch')) {
      return const WorkflowStatusPresentation(
        key: 'dispatched',
        label: 'Dispatched',
        color: AppTheme.colorFF1A3A6B,
        icon: Icons.route_outlined,
      );
    }
    if (normalized.contains('ready')) {
      return const WorkflowStatusPresentation(
        key: 'ready_to_dispatch',
        label: 'Ready to Dispatch',
        color: AppTheme.primaryBlue,
        icon: Icons.outbound_outlined,
      );
    }

    return const WorkflowStatusPresentation(
      key: 'pending',
      label: 'Pending',
      color: AppTheme.neutralGray,
      icon: Icons.pending_outlined,
    );
  }

  static WorkflowStatusPresentation invoice(dynamic status) {
    final normalized = _normalize(status);

    if (normalized.contains('void')) {
      return const WorkflowStatusPresentation(
        key: 'voided',
        label: 'Voided',
        color: AppTheme.neutralGray,
        icon: Icons.block,
        strikethrough: true,
      );
    }
    if (normalized.contains('paid') || normalized.contains('collected')) {
      return const WorkflowStatusPresentation(
        key: 'paid',
        label: 'Paid',
        color: Color(0xFF065F46),
        icon: Icons.payments_outlined,
      );
    }
    if (normalized.contains('overdue') || normalized.contains('late')) {
      return const WorkflowStatusPresentation(
        key: 'overdue',
        label: 'Overdue',
        color: AppTheme.colorFF7F1D1D,
        icon: Icons.warning_amber_rounded,
      );
    }
    if (normalized.contains('partial')) {
      return const WorkflowStatusPresentation(
        key: 'partial',
        label: 'Partial',
        color: AppTheme.warningOrange,
        icon: Icons.pending_actions_outlined,
      );
    }
    if (normalized.contains('reject')) {
      return const WorkflowStatusPresentation(
        key: 'rejected',
        label: 'Rejected',
        color: AppTheme.errorRed,
        icon: Icons.cancel_outlined,
      );
    }
    if (normalized.contains('issue') ||
        normalized.contains('sent') ||
        normalized.contains('unpaid')) {
      return const WorkflowStatusPresentation(
        key: 'issued',
        label: 'Issued',
        color: AppTheme.pioneerRed,
        icon: Icons.receipt_long_outlined,
      );
    }
    if (normalized.contains('approve')) {
      return const WorkflowStatusPresentation(
        key: 'approved',
        label: 'Approved',
        color: AppTheme.primaryBlue,
        icon: Icons.verified_outlined,
      );
    }
    if (normalized.contains('draft')) {
      return const WorkflowStatusPresentation(
        key: 'draft',
        label: 'Draft',
        color: AppTheme.neutralGray,
        icon: Icons.edit_note_outlined,
      );
    }

    return const WorkflowStatusPresentation(
      key: 'issued',
      label: 'Issued',
      color: AppTheme.pioneerRed,
      icon: Icons.receipt_long_outlined,
    );
  }

  static WorkflowStatusPresentation clientTracking(dynamic status) {
    return trip(status);
  }

  static String disabledActionReason({
    required String action,
    dynamic status,
    bool hasPod = true,
    bool hasDriver = true,
    bool hasVehicle = true,
    bool isPaid = false,
  }) {
    final normalized = _normalize(status);
    if (action == 'dispatch') {
      if (!hasDriver) return 'Cannot dispatch - no driver assigned';
      if (!hasVehicle) return 'Cannot dispatch - no vehicle assigned';
      if (!normalized.contains('pending') && normalized.isNotEmpty) {
        return 'Cannot dispatch - trip is already ${trip(status).label}';
      }
      return 'Cannot dispatch - trip is not ready to dispatch';
    }
    if (action == 'invoice') {
      if (!hasPod) return 'Cannot invoice - POD not confirmed';
      if (!normalized.contains('complete') && !normalized.contains('ready')) {
        return 'Cannot invoice - trip is not completed';
      }
      return 'Cannot invoice - trip is not ready to bill';
    }
    if (action == 'void' && isPaid) {
      return 'Cannot void - invoice already paid';
    }

    return 'Action unavailable for the current workflow state';
  }

  static String _normalize(dynamic value) {
    return (value ?? '').toString().trim().toLowerCase().replaceAll('_', ' ');
  }
}
