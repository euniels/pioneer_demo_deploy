class DispatchWorkflowPolicy {
  const DispatchWorkflowPolicy._();

  static int phaseNumber(Map<String, dynamic> trip, {int fallback = 1}) {
    final raw = trip['workflowPhaseNumber'];
    if (raw is num) return raw.toInt().clamp(1, 12);
    final parsed = int.tryParse(raw?.toString() ?? '');
    if (parsed != null) return parsed.clamp(1, 12);

    final status = (trip['status'] ?? '').toString().trim().toLowerCase();
    return switch (status.replaceAll('_', ' ')) {
      'completed' || 'delivered' || 'verified' => 12,
      'pending approval' => 12,
      'arrived' => 11,
      'dispatched' || 'active' || 'in transit' || 'on trip' || 'in progress' => 10,
      'pending' => 1,
      _ => fallback.clamp(1, 12),
    };
  }

  static String groupForPhase(int phase) {
    if (phase <= 2) return 'Pending Details';
    if (phase <= 6) return 'Pending Assignment';
    if (phase <= 9) return 'Ready to Dispatch';
    if (phase == 10) return 'In Transit';
    if (phase == 11) return 'Arrived / POD Needed';
    return 'Completed / POD Review Handoff';
  }

  static String labelForPhase(int phase) {
    if (phase <= 2) return 'Trip request';
    if (phase <= 6) return 'Dispatch assignment';
    if (phase <= 9) return 'Ready to dispatch';
    if (phase == 10) return 'In transit';
    if (phase == 11) return 'Arrived / POD needed';
    return 'Completed / POD review handoff';
  }

  static String nextActionForPhase(int phase) {
    if (phase <= 2) return 'Complete the delivery trip details.';
    if (phase <= 6) return 'Assign vehicle, driver, and dispatch notification.';
    if (phase <= 9) return 'Start dispatch when driver and vehicle are ready.';
    if (phase == 10) return 'Mark arrived when the vehicle reaches the destination.';
    if (phase == 11) return 'Waiting for POD/admin review before completion.';
    return 'Accounting reviews billing after POD verification.';
  }

  static String dispatchActionLabel(int phase) {
    if (phase <= 8) return 'Continue Setup';
    if (phase == 9) return 'Start Dispatch';
    if (phase == 10) return 'Mark Arrived';
    if (phase == 11) return 'Waiting for POD';
    return 'POD Review Handoff';
  }

  static bool hasAssignedDriver(Map<String, dynamic> trip) {
    final driver = (trip['driver'] ?? '').toString().trim().toLowerCase();
    return driver.isNotEmpty &&
        driver != 'n/a' &&
        driver != 'unassigned' &&
        driver != 'unassigned driver';
  }

  static bool hasAssignedVehicle(Map<String, dynamic> trip) {
    final vehicle = (trip['vehicle'] ?? '').toString().trim().toLowerCase();
    return vehicle.isNotEmpty &&
        vehicle != 'n/a' &&
        vehicle != 'unassigned' &&
        vehicle != 'unassigned vehicle';
  }

  static String? blockedReason(Map<String, dynamic> trip) {
    final phase = phaseNumber(trip);
    final status = (trip['status'] ?? '').toString().trim().toLowerCase();

    if (phase >= 12 || status == 'completed') {
      return 'Completion is handled through POD review and billing.';
    }
    if (phase == 11 || status == 'pending_approval') {
      return 'Waiting for POD/admin review before the workflow can continue.';
    }
    if (phase >= 9 && !hasAssignedDriver(trip)) {
      return 'Assign a driver before starting dispatch.';
    }
    if (phase >= 9 && !hasAssignedVehicle(trip)) {
      return 'Assign a vehicle before starting dispatch.';
    }
    if (phase == 10 && !_isActiveDispatchStatus(status)) {
      return 'The trip must be dispatched before marking arrival.';
    }

    return null;
  }

  static Map<String, dynamic> nextDispatchUpdates(Map<String, dynamic> trip) {
    final current = phaseNumber(trip);
    final next = current >= 10 ? 11 : current + 1;

    return {
      'workflowPhaseNumber': next,
      if (next == 10) 'status': 'dispatched',
      if (next == 10) 'startedAt': DateTime.now().toIso8601String(),
      if (next == 11) 'status': 'dispatched',
    };
  }

  static bool _isActiveDispatchStatus(String status) {
    return status == 'dispatched' ||
        status == 'active' ||
        status == 'in transit' ||
        status == 'on trip' ||
        status == 'in progress';
  }
}
