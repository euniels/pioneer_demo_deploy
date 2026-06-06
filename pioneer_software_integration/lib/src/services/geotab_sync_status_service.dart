import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'drivers_store.dart';
import 'vehicles_store.dart';

final ValueNotifier<Map<String, dynamic>?> geotabWriteBackEventNotifier =
    ValueNotifier<Map<String, dynamic>?>(null);

class GeoTabSyncVisual {
  const GeoTabSyncVisual({
    required this.status,
    required this.label,
    required this.color,
    required this.icon,
    this.pulsing = false,
    this.tooltip,
    this.canPush = false,
  });

  final String status;
  final String label;
  final Color color;
  final IconData icon;
  final bool pulsing;
  final String? tooltip;
  final bool canPush;
}

GeoTabSyncVisual geoTabSyncVisualFromEntity(Map<String, dynamic> entity) {
  return geoTabSyncVisual(
    entity['syncStatus']?.toString(),
    explicitLabel: entity['syncLabel']?.toString(),
    error: entity['syncError']?.toString() ?? entity['lastError']?.toString(),
  );
}

GeoTabSyncVisual geoTabSyncVisual(
  String? rawStatus, {
  String? explicitLabel,
  String? error,
}) {
  final status = _normalizeSyncStatus(rawStatus);
  final label = _labelFor(status, explicitLabel);
  final cleanError = (error ?? '').trim();
  final tooltip = cleanError.isEmpty ? label : '$label\n$cleanError';

  return switch (status) {
    'synced' => GeoTabSyncVisual(
      status: status,
      label: label,
      color: AppTheme.successGreen,
      icon: Icons.cloud_done_rounded,
      tooltip: tooltip,
    ),
    'local_modified' => GeoTabSyncVisual(
      status: status,
      label: label,
      color: AppTheme.warningOrange,
      icon: Icons.edit_note_rounded,
      tooltip: tooltip,
      canPush: true,
    ),
    'pending_approval' => GeoTabSyncVisual(
      status: status,
      label: label,
      color: AppTheme.primaryBlue,
      icon: Icons.admin_panel_settings_rounded,
      tooltip: tooltip,
    ),
    'processing' => GeoTabSyncVisual(
      status: status,
      label: label,
      color: AppTheme.primaryBlue,
      icon: Icons.sync_rounded,
      tooltip: tooltip,
      pulsing: true,
    ),
    'failed' => GeoTabSyncVisual(
      status: status,
      label: label,
      color: AppTheme.errorRed,
      icon: Icons.error_outline_rounded,
      tooltip: tooltip,
      canPush: true,
    ),
    'permanently_failed' => GeoTabSyncVisual(
      status: status,
      label: label,
      color: AppTheme.colorFF7F1D1D,
      icon: Icons.report_gmailerrorred_rounded,
      tooltip:
          '$tooltip\nRetries are exhausted. Contact a GeoTab administrator or system admin before trying again.',
    ),
    _ => GeoTabSyncVisual(
      status: status,
      label: label,
      color: AppTheme.neutralGray,
      icon: Icons.cloud_off_rounded,
      tooltip: tooltip,
    ),
  };
}

bool canPushToGeotab(Map<String, dynamic> entity) {
  if (entity['canPushToGeotab'] == true ||
      entity['hasLocalGeotabChanges'] == true) {
    return true;
  }

  return geoTabSyncVisualFromEntity(entity).canPush;
}

void applyGeotabWriteBackEvent(Map<String, dynamic> payload) {
  final job = payload['job'];
  if (job is! Map) {
    return;
  }

  final normalizedJob = job.map(
    (key, value) => MapEntry(key.toString(), value),
  );
  final operations = ((normalizedJob['operations'] as List?) ?? const [])
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .toList();

  if (operations.isEmpty) {
    _applyWriteBackTarget(normalizedJob);
  } else {
    for (final operation in operations) {
      _applyWriteBackTarget({...normalizedJob, ...operation});
    }
  }

  geotabWriteBackEventNotifier.value = normalizedJob;
}

void _applyWriteBackTarget(Map<String, dynamic> target) {
  final localType = target['localType']?.toString() ?? '';
  final localId = target['localId']?.toString() ?? '';
  if (localId.isEmpty) {
    return;
  }

  final patch = {
    'syncStatus': target['syncStatus'] ?? target['status'],
    'syncLabel': target['syncLabel'],
    'syncError': target['lastError'],
    'pendingWriteJobId': target['pendingWriteJobId'],
    'hasLocalGeotabChanges': target['syncStatus'] == 'local_modified',
    'canPushToGeotab':
        target['syncStatus'] == 'local_modified' ||
        target['syncStatus'] == 'failed',
  };

  if (localType == 'manual_driver') {
    driversNotifier.value = driversNotifier.value.map((driver) {
      final id = driver['id']?.toString() ?? '';
      if (id == localId || id == 'manual-$localId') {
        return {...driver, ...patch};
      }
      return driver;
    }).toList();
  } else if (localType == 'manual_vehicle') {
    vehiclesNotifier.value = vehiclesNotifier.value.map((vehicle) {
      final id =
          vehicle['localId']?.toString() ??
          vehicle['id']?.toString().replaceFirst('manual-vehicle-', '') ??
          '';
      if (id == localId) {
        return {...vehicle, ...patch};
      }
      return vehicle;
    }).toList();
  }
}

String _normalizeSyncStatus(String? rawStatus) {
  final status = (rawStatus ?? '').trim().toLowerCase();
  return switch (status) {
    'up_to_date' || 'up-to-date' => 'synced',
    'not_staged' || 'not_synced' || 'never_synced' || '' => 'not_synced',
    'approved' || 'processing' || 'executing' => 'processing',
    'rejected' => 'failed',
    _ => status,
  };
}

String _labelFor(String status, String? explicitLabel) {
  final explicit = (explicitLabel ?? '').trim();
  if (explicit.startsWith('GeoTab:')) {
    return explicit;
  }

  return switch (status) {
    'synced' => 'GeoTab: Up to date',
    'local_modified' => 'GeoTab: Local changes pending',
    'pending_approval' => 'GeoTab: Push awaiting approval',
    'processing' => 'GeoTab: Push approved, executing',
    'failed' => 'GeoTab: Sync failed',
    'permanently_failed' => 'GeoTab: Permanently failed',
    _ => 'GeoTab: Never synced',
  };
}
