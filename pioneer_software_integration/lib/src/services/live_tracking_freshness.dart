import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum LiveTrackingFreshnessState {
  live,
  cached,
  stale,
  geotabUnavailable,
  noVehicles,
}

class LiveTrackingFreshness {
  const LiveTrackingFreshness({
    required this.state,
    required this.label,
    required this.detail,
    required this.color,
    required this.icon,
  });

  final LiveTrackingFreshnessState state;
  final String label;
  final String detail;
  final Color color;
  final IconData icon;

  bool get isLive => state == LiveTrackingFreshnessState.live;
  bool get isStale =>
      state == LiveTrackingFreshnessState.stale ||
      state == LiveTrackingFreshnessState.geotabUnavailable;
}

class LiveTrackingFreshnessResolver {
  const LiveTrackingFreshnessResolver._();

  static LiveTrackingFreshness forVehicle(
    Map<String, dynamic> vehicle, {
    DateTime? now,
  }) {
    final sampleAt = now ?? DateTime.now().toUtc();
    final syncState = (vehicle['syncState'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final geotabAvailable = _boolOrNull(
      vehicle['geotabAvailable'] ?? vehicle['geotab_available'],
    );

    if (geotabAvailable == false || syncState == 'geotab_unavailable') {
      return const LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.geotabUnavailable,
        label: 'GeoTab unavailable',
        detail: 'Feed unavailable',
        color: AppTheme.errorRed,
        icon: Icons.cloud_off_rounded,
      );
    }

    final age = _age(vehicle, sampleAt);
    if (age == null) {
      return const LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.cached,
        label: 'Cached',
        detail: 'Waiting for timestamp',
        color: AppTheme.primaryBlue,
        icon: Icons.storage_rounded,
      );
    }

    if (age <= const Duration(seconds: 60) &&
        syncState != 'offline_cached' &&
        syncState != 'stale') {
      return LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.live,
        label: 'Live',
        detail: 'Updated ${_ageLabel(age)} ago',
        color: AppTheme.successGreen,
        icon: Icons.radio_button_checked_rounded,
      );
    }

    if (age <= const Duration(minutes: 5)) {
      return LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.cached,
        label: 'Cached',
        detail: 'Updated ${_ageLabel(age)} ago',
        color: AppTheme.primaryBlue,
        icon: Icons.storage_rounded,
      );
    }

    return LiveTrackingFreshness(
      state: LiveTrackingFreshnessState.stale,
      label: 'Stale',
      detail: 'Stale - ${_ageLabel(age)} ago',
      color: AppTheme.warningOrange,
      icon: Icons.schedule_rounded,
    );
  }

  static LiveTrackingFreshness forFleet(
    List<Map<String, dynamic>> vehicles, {
    DateTime? now,
  }) {
    if (vehicles.isEmpty) {
      return const LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.noVehicles,
        label: 'No vehicles',
        detail: 'No vehicles exist in local database',
        color: AppTheme.neutralGray,
        icon: Icons.local_shipping_outlined,
      );
    }

    final states = vehicles
        .map((vehicle) => forVehicle(vehicle, now: now).state)
        .toSet();
    if (states.contains(LiveTrackingFreshnessState.live)) {
      return const LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.live,
        label: 'Live',
        detail: 'At least one vehicle updated within 60 seconds',
        color: AppTheme.successGreen,
        icon: Icons.radio_button_checked_rounded,
      );
    }
    if (states.contains(LiveTrackingFreshnessState.cached)) {
      return const LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.cached,
        label: 'Cached',
        detail: 'Showing recently cached fleet positions',
        color: AppTheme.primaryBlue,
        icon: Icons.storage_rounded,
      );
    }
    if (states.contains(LiveTrackingFreshnessState.geotabUnavailable)) {
      return const LiveTrackingFreshness(
        state: LiveTrackingFreshnessState.geotabUnavailable,
        label: 'GeoTab unavailable',
        detail: 'Serving cached/local fleet data',
        color: AppTheme.errorRed,
        icon: Icons.cloud_off_rounded,
      );
    }
    return const LiveTrackingFreshness(
      state: LiveTrackingFreshnessState.stale,
      label: 'Stale',
      detail: 'All positions are older than 5 minutes',
      color: AppTheme.warningOrange,
      icon: Icons.schedule_rounded,
    );
  }

  static Duration? _age(Map<String, dynamic> vehicle, DateTime now) {
    final sourceAge = _intOrNull(vehicle['sourceAgeMs']);
    if (sourceAge != null && sourceAge >= 0) {
      return Duration(milliseconds: sourceAge);
    }

    final timestamp = _parseDate(vehicle['lastGeotabAt']) ??
        _parseDate(vehicle['lastUpdated']);
    if (timestamp == null) {
      return null;
    }
    final age = now.difference(timestamp.toUtc());
    return age.isNegative ? Duration.zero : age;
  }

  static DateTime? _parseDate(dynamic raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  static int? _intOrNull(dynamic raw) {
    if (raw is num) {
      return raw.toInt();
    }
    return int.tryParse(raw?.toString() ?? '');
  }

  static bool? _boolOrNull(dynamic raw) {
    if (raw is bool) {
      return raw;
    }
    final value = raw?.toString().trim().toLowerCase() ?? '';
    if (value == 'true' || value == '1') {
      return true;
    }
    if (value == 'false' || value == '0') {
      return false;
    }
    return null;
  }

  static String _ageLabel(Duration age) {
    if (age.inSeconds < 60) {
      return '${age.inSeconds}s';
    }
    if (age.inMinutes < 60) {
      return '${age.inMinutes} min';
    }
    return '${age.inHours} hr';
  }
}
