import 'dart:async';

import 'package:flutter/material.dart';

import '../services/backend_api.dart';
import '../services/vehicles_store.dart';
import '../utils/display_format.dart';
import '../widgets/geotab_sync_status_badge.dart';
import '../theme/app_theme.dart';

enum _VehicleAssetSource { fresh, persisted, snapshot }

class VehicleDetailsModal extends StatefulWidget {
  final Map<String, dynamic> vehicle;

  const VehicleDetailsModal({required this.vehicle, super.key});

  @override
  State<VehicleDetailsModal> createState() => _VehicleDetailsModalState();
}

class _VehicleDetailsModalState extends State<VehicleDetailsModal> {
  Map<String, dynamic>? _asset;
  bool _isLoading = false;
  String? _errorMessage;
  Timer? _pendingRetryTimer;
  Timer? _storeDebounceTimer;
  int _consecutiveRefreshFailures = 0;
  _VehicleAssetSource _resolvedSource = _VehicleAssetSource.snapshot;
  DateTime? _resolvedTimestamp;

  Map<String, dynamic>? get _storeVehicle {
    final geotabId = widget.vehicle['geotabId']?.toString().trim() ?? '';
    if (geotabId.isEmpty) {
      return null;
    }

    for (final vehicle in vehiclesNotifier.value) {
      final candidateId = vehicle['geotabId']?.toString().trim() ?? '';
      if (candidateId == geotabId) {
        return vehicle;
      }
    }

    return null;
  }

  Map<String, dynamic> get _view {
    final merged = Map<String, dynamic>.from(widget.vehicle);
    final store = _storeVehicle;
    if (store != null) {
      _overlayMeaningfulValues(merged, store);
    }

    final asset = _asset;
    if (asset != null) {
      _overlayMeaningfulValues(merged, asset);
    }

    return merged;
  }

  @override
  void initState() {
    super.initState();
    vehiclesNotifier.addListener(_onVehiclesChanged);
    _refreshResolvedSource();
    _loadAssetDetails();
  }

  @override
  void dispose() {
    _pendingRetryTimer?.cancel();
    _storeDebounceTimer?.cancel();
    if (_hasFreshAsset(_asset)) {
      final geotabId = widget.vehicle['geotabId']?.toString().trim() ?? '';
      final asset = _asset;
      if (geotabId.isNotEmpty && asset != null && asset.isNotEmpty) {
        unawaited(
          BackendApiService.persistFleetTelemetryAsset(
            geotabId,
            Map<String, dynamic>.from(asset),
          ),
        );
      }
    }
    vehiclesNotifier.removeListener(_onVehiclesChanged);
    super.dispose();
  }

  void _onVehiclesChanged() {
    if (!mounted) {
      return;
    }

    final store = _storeVehicle;
    if (store == null) {
      return;
    }

    _storeDebounceTimer?.cancel();
    _storeDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) {
        return;
      }

      setState(_refreshResolvedSource);
    });
  }

  Future<void> _loadAssetDetails({bool forceRefresh = false}) async {
    final geotabId = widget.vehicle['geotabId']?.toString().trim() ?? '';
    if (geotabId.isEmpty) {
      return;
    }

    setState(() {
      _isLoading = true;
      if (_resolvedSource != _VehicleAssetSource.persisted) {
        _errorMessage = null;
      }
    });

    try {
      final asset = await BackendApiService.getFleetTelemetryAsset(
        geotabId,
        forceRefresh: forceRefresh,
      ).timeout(const Duration(seconds: 8));
      if (!mounted) {
        return;
      }

      setState(() {
        _asset = asset;
        _isLoading = false;
        _errorMessage = _hasFreshAsset(asset) ? null : _errorMessage;
        if (_hasFreshAsset(asset)) {
          _consecutiveRefreshFailures = 0;
        } else {
          _consecutiveRefreshFailures += 1;
        }
        _refreshResolvedSource();
      });

      if (_shouldKeepRefreshing(asset)) {
        _scheduleBackgroundRefresh();
      } else {
        _stopBackgroundRefreshTimer();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = error.toString();
        _consecutiveRefreshFailures += 1;
        _refreshResolvedSource();
      });

      _scheduleBackgroundRefresh();
    }
  }

  void _scheduleBackgroundRefresh() {
    _pendingRetryTimer?.cancel();
    final delay = _retryDelayForFailureCount(_consecutiveRefreshFailures);
    _pendingRetryTimer = Timer(delay, () {
      _pendingRetryTimer = null;
      if (!mounted) {
        return;
      }

      if (_hasFreshAsset(_asset)) {
        _stopBackgroundRefreshTimer();
        return;
      }

      if (_isLoading) {
        _scheduleBackgroundRefresh();
        return;
      }

      _loadAssetDetails(forceRefresh: true);
    });
  }

  void _stopBackgroundRefreshTimer() {
    _pendingRetryTimer?.cancel();
    _pendingRetryTimer = null;
  }

  bool _hasFreshAsset(Map<String, dynamic>? asset) {
    if (asset == null || asset.isEmpty) {
      return false;
    }

    final syncState = asset['syncState']?.toString().trim().toLowerCase();
    if (syncState == 'offline_cached' || syncState == 'stale') {
      return false;
    }

    return asset['stale'] != true;
  }

  bool _hasPersistedOrFreshAsset() {
    final asset = _asset;
    return asset != null && asset.isNotEmpty;
  }

  bool _shouldKeepRefreshing(Map<String, dynamic> asset) {
    return !_hasFreshAsset(asset);
  }

  Duration _retryDelayForFailureCount(int failureCount) {
    if (failureCount <= 1) {
      return const Duration(seconds: 18);
    }
    if (failureCount == 2) {
      return const Duration(seconds: 36);
    }
    if (failureCount == 3) {
      return const Duration(seconds: 72);
    }
    return const Duration(seconds: 90);
  }

  void _refreshResolvedSource() {
    if (_hasFreshAsset(_asset)) {
      _resolvedSource = _VehicleAssetSource.fresh;
      _resolvedTimestamp = _extractFreshTimestamp(_asset);
      return;
    }

    if (_hasPersistedOrFreshAsset()) {
      _resolvedSource = _VehicleAssetSource.persisted;
      _resolvedTimestamp = _extractPersistedTimestamp(_asset);
      return;
    }

    _resolvedSource = _VehicleAssetSource.snapshot;
    _resolvedTimestamp =
        _extractTimestamp(_storeVehicle) ?? _extractTimestamp(widget.vehicle);
  }

  DateTime? _extractFreshTimestamp(Map<String, dynamic>? source) {
    return _extractTimestamp(source);
  }

  DateTime? _extractPersistedTimestamp(Map<String, dynamic>? source) {
    return _parseTimestamp(source?['persistedAt']) ??
        _parseTimestamp(source?['lastSyncedAt']) ??
        _extractTimestamp(source) ??
        _extractTimestamp(_storeVehicle) ??
        _extractTimestamp(widget.vehicle);
  }

  DateTime? _extractTimestamp(Map<String, dynamic>? source) {
    return _parseTimestamp(source?['lastGeotabAt']) ??
        _parseTimestamp(source?['lastUpdated']) ??
        _parseTimestamp(source?['lastSyncedAt']);
  }

  DateTime? _parseTimestamp(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw)?.toLocal();
  }

  String? get _metricFreshnessLabel {
    if (_resolvedSource == _VehicleAssetSource.fresh) {
      return null;
    }

    final timestamp = _resolvedTimestamp;
    if (timestamp == null) {
      return 'Last updated recently';
    }

    final elapsed = DateTime.now().difference(timestamp);
    if (elapsed.inMinutes < 1) {
      return 'Last updated just now';
    }
    if (elapsed.inHours < 1) {
      return 'Last updated ${elapsed.inMinutes}m ago';
    }
    if (elapsed.inDays < 1) {
      return 'Last updated ${elapsed.inHours}h ago';
    }
    return 'Last updated ${elapsed.inDays}d ago';
  }

  dynamic _resolvedValueForKey(String key) {
    final assetValue = _asset?[key];
    if (_isMeaningfulValue(assetValue)) {
      return assetValue;
    }

    final storeValue = _storeVehicle?[key];
    if (_isMeaningfulValue(storeValue)) {
      return storeValue;
    }

    return widget.vehicle[key];
  }

  Map<String, dynamic> _resolvedDiagnostic(String alias) {
    final merged = <String, dynamic>{};
    final snapshotDiagnostic = _map(_map(widget.vehicle['diagnostics'])[alias]);
    final storeDiagnostic = _map(_map(_storeVehicle?['diagnostics'])[alias]);
    final assetDiagnostic = _map(_map(_asset?['diagnostics'])[alias]);
    _overlayMeaningfulValues(merged, snapshotDiagnostic);
    _overlayMeaningfulValues(merged, storeDiagnostic);
    _overlayMeaningfulValues(merged, assetDiagnostic);
    return merged;
  }

  void _overlayMeaningfulValues(
    Map<String, dynamic> target,
    Map<String, dynamic> source,
  ) {
    source.forEach((key, value) {
      if (!_isMeaningfulValue(value)) {
        return;
      }

      if (value is Map) {
        final current = target[key];
        final nested = <String, dynamic>{};
        if (current is Map) {
          nested.addAll(
            current.map((nestedKey, nestedValue) {
              return MapEntry(nestedKey.toString(), nestedValue);
            }),
          );
        }
        _overlayMeaningfulValues(
          nested,
          value.map((nestedKey, nestedValue) {
            return MapEntry(nestedKey.toString(), nestedValue);
          }),
        );
        target[key] = nested;
        return;
      }

      target[key] = value;
    });
  }

  bool _isMeaningfulValue(dynamic value) {
    if (value == null) {
      return false;
    }
    if (value is String) {
      return value.trim().isNotEmpty;
    }
    if (value is Map) {
      return value.isNotEmpty;
    }
    if (value is Iterable) {
      return value.isNotEmpty;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final healthStatus = _string(_view['healthStatus'], fallback: 'healthy');
    final healthColor = _healthColor(healthStatus);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF10141D : AppTheme.colorFFF4F6F8,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          _buildHeader(isDark, healthColor),
          Expanded(
            child: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                  children: [
                    _buildHeroStats(isDark),
                    const SizedBox(height: 18),
                    _buildSectionCard(
                      isDark: isDark,
                      title: 'Asset Intelligence',
                      icon: Icons.local_shipping_rounded,
                      child: _buildAssetGrid(isDark),
                    ),
                    const SizedBox(height: 18),
                    _buildSectionCard(
                      isDark: isDark,
                      title: 'Route And Geofence',
                      icon: Icons.route_rounded,
                      child: _buildRouteSection(isDark),
                    ),
                    const SizedBox(height: 18),
                    _buildSectionCard(
                      isDark: isDark,
                      title: 'Diagnostics',
                      icon: Icons.monitor_heart_rounded,
                      child: _buildDiagnosticsGrid(isDark),
                    ),
                    const SizedBox(height: 18),
                    _buildSectionCard(
                      isDark: isDark,
                      title: 'Vehicle Health',
                      icon: Icons.health_and_safety_rounded,
                      child: _buildHealthSection(isDark),
                    ),
                    const SizedBox(height: 18),
                    _buildSectionCard(
                      isDark: isDark,
                      title: 'Maintenance And Fuel History',
                      icon: Icons.history_rounded,
                      child: _buildHistorySection(isDark),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isDark, Color healthColor) {
    final plate = _string(_view['plate'], fallback: 'UNKNOWN');
    final truckType = _string(_view['truckType'], fallback: 'Truck');
    final healthStatus = _string(_view['healthStatus'], fallback: 'healthy');
    final healthScore = _intValue(_view['healthScore']);

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? const [AppTheme.colorFF142033, AppTheme.colorFF0C1220]
              : const [AppTheme.colorFF203A55, AppTheme.colorFF0F1A2A],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppTheme.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.local_shipping_rounded,
                  color: AppTheme.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plate,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.white,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      truckType,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.white.withValues(alpha: 0.78),
                      ),
                    ),
                    if (_view.containsKey('syncStatus')) ...[
                      const SizedBox(height: 8),
                      GeoTabSyncStatusBadge.fromEntity(_view, compact: true),
                    ],
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isLoading) ...[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  GestureDetector(
                    onTap: _isLoading
                        ? null
                        : () => _loadAssetDetails(forceRefresh: true),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.refresh_rounded,
                        color: _isLoading
                            ? AppTheme.white.withValues(alpha: 0.45)
                            : AppTheme.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.white,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _pill(
                icon: Icons.favorite_rounded,
                label:
                    '${healthStatus[0].toUpperCase()}${healthStatus.substring(1)} - $healthScore',
                color: healthColor,
              ),
              const SizedBox(width: 10),
              _pill(
                icon: Icons.sensors_rounded,
                label: _string(
                  _view['isCommunicating'] == true ? 'Online' : 'Offline',
                  fallback: 'Offline',
                ),
                color: _view['isCommunicating'] == true
                    ? AppTheme.colorFF2ECC71
                    : AppTheme.colorFFE74C3C,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeroStats(bool isDark) {
    final fuel = _resolvedDiagnostic('fuelLevel');
    final fuelEconomy = _doubleValue(
      _resolvedValueForKey('fuelEconomyKmPerLiter'),
    );
    final freshnessLabel = _metricFreshnessLabel;
    final odometerText = _string(
      _resolvedValueForKey('mileage'),
      fallback: _formatted(_doubleValue(_resolvedValueForKey('odometerKm'))),
    );
    final engineHoursText = _formatted(
      _doubleValue(_resolvedValueForKey('engineHours')),
    );
    final directFuelText = _string(fuel['displayValue']);
    final fuelText =
        directFuelText.isNotEmpty &&
            directFuelText.toLowerCase() != 'unavailable'
        ? directFuelText
        : _formattedPercent(
            _doubleValue(_resolvedValueForKey('fuelLevelRatio')) * 100,
          );

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _metricTile(
                isDark: isDark,
                label: 'Odometer',
                value: odometerText,
                suffix: 'km',
                icon: Icons.speed_rounded,
                accent: AppTheme.colorFF4B7BE5,
                helperText: freshnessLabel,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _metricTile(
                isDark: isDark,
                label: 'Engine Hours',
                value: engineHoursText,
                suffix: 'hr',
                icon: Icons.av_timer_rounded,
                accent: AppTheme.colorFF27AE60,
                helperText: freshnessLabel,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _metricTile(
                isDark: isDark,
                label: 'Fuel Level',
                value: fuelText,
                icon: Icons.local_gas_station_rounded,
                accent: AppTheme.colorFFF39C12,
                helperText: freshnessLabel,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _metricTile(
                isDark: isDark,
                label: 'Fuel Economy',
                value: fuelEconomy > 0 ? fuelEconomy.toStringAsFixed(1) : 'N/A',
                suffix: fuelEconomy > 0 ? 'km/L' : null,
                icon: Icons.trending_up_rounded,
                accent: AppTheme.colorFF9B59B6,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAssetGrid(bool isDark) {
    final tags = _list(_view['assetTags']);

    return Column(
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            _infoPill(
              isDark,
              'Driver',
              _string(_view['driver'], fallback: 'Unassigned'),
            ),
            _infoPill(
              isDark,
              'Vehicle Type',
              _string(
                _view['vehicleType'] ?? _view['truckType'],
                fallback: 'N/A',
              ),
            ),
            _infoPill(
              isDark,
              'Make / Model',
              _string(_view['makeModel'], fallback: 'N/A'),
            ),
            _infoPill(
              isDark,
              'Cargo Capacity',
              _string(_view['cargoCapacityKg'], fallback: 'N/A') == 'N/A'
                  ? 'N/A'
                  : '${_string(_view['cargoCapacityKg'])} kg',
            ),
            _infoPill(
              isDark,
              'Registration',
              _expiryLabel(_view['registrationExpiryDate']),
              accent: _expiryColor(_view['registrationDaysRemaining']),
            ),
            _infoPill(
              isDark,
              'Insurance',
              _expiryLabel(_view['insuranceExpiryDate']),
              accent: _expiryColor(_view['insuranceDaysRemaining']),
            ),
            _infoPill(isDark, 'VIN', _string(_view['vin'], fallback: 'N/A')),
            _infoPill(
              isDark,
              'Serial',
              _string(_view['serialNumber'], fallback: 'N/A'),
            ),
            _infoPill(
              isDark,
              'Device',
              _string(_view['deviceType'], fallback: 'N/A'),
            ),
            _infoPill(
              isDark,
              'Delivery Fit',
              _string(_view['deliveryFit'], fallback: 'General multi-stop'),
            ),
            _infoPill(
              isDark,
              'Last Sync',
              _string(_view['lastUpdated'], fallback: 'N/A'),
            ),
          ],
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: tags
                  .map(
                    (tag) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.colorFF4B7BE5.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.colorFF4B7BE5,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRouteSection(bool isDark) {
    final routeStops = _listOfMaps(_view['routeStops']);
    final routeName = _string(_view['routeName'] ?? _view['assignedRoute']);
    final originZone = _string(_view['originZone']);
    final currentZone = _string(_view['currentZone']);
    final destinationZone = _string(_view['destinationZone']);
    final arrivalState = _string(_view['arrivalState'], fallback: 'idle');
    final currentLocationLabel = _string(_view['currentLocationLabel']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            _infoPill(
              isDark,
              'Route',
              routeName.isEmpty ? 'Unassigned' : routeName,
            ),
            _infoPill(
              isDark,
              'Origin',
              originZone.isEmpty ? 'N/A' : originZone,
            ),
            _infoPill(
              isDark,
              'Current Zone',
              currentZone.isEmpty ? 'Outside zone' : currentZone,
            ),
            _infoPill(
              isDark,
              'Destination',
              destinationZone.isEmpty ? 'N/A' : destinationZone,
            ),
            _infoPill(
              isDark,
              'Arrival',
              arrivalState.isEmpty ? 'Idle' : arrivalState,
            ),
          ],
        ),
        if (currentLocationLabel.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.colorFF171C26 : AppTheme.colorFFF8FAFB,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? AppTheme.white.withValues(alpha: 0.06)
                    : AppTheme.black.withValues(alpha: 0.05),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.place_rounded, color: AppTheme.colorFF4B7BE5),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    currentLocationLabel,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: isDark ? AppTheme.gray200 : AppTheme.colorFF243447,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        if (routeStops.isEmpty)
          Text(
            'No planned Geotab route stops were returned for this asset yet.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          )
        else
          Column(
            children: routeStops
                .map(
                  (stop) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppTheme.colorFF171C26
                          : AppTheme.colorFFF8FAFB,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? AppTheme.white.withValues(alpha: 0.06)
                            : AppTheme.black.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF4B7BE5,
                            ).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: Text(
                              '${_intValue(stop['sequence'])}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.colorFF4B7BE5,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _string(stop['name'], fallback: 'Unnamed stop'),
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? AppTheme.white
                                      : AppTheme.colorFF243447,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'ETA ${_string(stop['eta'], fallback: 'N/A')}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark
                                      ? AppTheme.gray400
                                      : AppTheme.gray600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () {
              final navigator = Navigator.of(context);
              final plate = _string(_view['plate'], fallback: '');
              navigator.pop();
              navigator.pushNamed(
                '/live-tracking',
                arguments: {'plate': plate},
              );
            },
            icon: const Icon(Icons.map_rounded),
            label: const Text('Open Live Map'),
          ),
        ),
      ],
    );
  }

  Widget _buildDiagnosticsGrid(bool isDark) {
    final aliases = <String>[
      'fuelLevel',
      'fuelTankCapacity',
      'engineCoolantTemperature',
      'outsideTemperature',
      'relativeHumidity',
      'engineCoolingFanSpeed',
      'batteryVoltage',
      'rawOdometer',
    ];

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: aliases.map((alias) {
        final diagnostic = _resolvedDiagnostic(alias);
        final displayValue = _diagnosticDisplayValue(alias, diagnostic);
        return SizedBox(
          width: 220,
          child: _metricTile(
            isDark: isDark,
            label: _string(diagnostic['label'], fallback: alias),
            value: displayValue,
            icon: _diagnosticIcon(alias),
            accent: _diagnosticColor(alias),
          ),
        );
      }).toList(),
    );
  }

  String _diagnosticDisplayValue(
    String alias,
    Map<String, dynamic> diagnostic,
  ) {
    final direct = _string(diagnostic['displayValue']);
    if (direct.isNotEmpty && direct.toLowerCase() != 'unavailable') {
      return direct;
    }

    switch (alias) {
      case 'fuelTankCapacity':
        final capacity = _string(_resolvedValueForKey('fuelCapacity'));
        return capacity.isEmpty || capacity == 'N/A' ? 'N/A' : '$capacity L';
      case 'rawOdometer':
        final odometer = _doubleValue(_resolvedValueForKey('odometerKm'));
        return odometer > 0 ? '${odometer.toStringAsFixed(0)} km' : 'N/A';
      case 'fuelLevel':
        final levelRatio = _doubleValue(_resolvedValueForKey('fuelLevelRatio'));
        return levelRatio > 0
            ? '${(levelRatio * 100).toStringAsFixed(0)}%'
            : 'N/A';
      default:
        return 'N/A';
    }
  }

  Widget _buildHealthSection(bool isDark) {
    final faults = _listOfMaps(_view['recentFaults']);
    final exceptions = _listOfMaps(_view['recentExceptions']);
    final healthAlerts = _map(_view['healthAlerts']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _alertChip(
              label: 'Offline',
              active: healthAlerts['offline'] == true,
              color: AppTheme.colorFFE74C3C,
            ),
            _alertChip(
              label: 'Low Fuel',
              active: healthAlerts['lowFuel'] == true,
              color: AppTheme.colorFFF39C12,
            ),
            _alertChip(
              label: 'Engine Hot',
              active: healthAlerts['engineHot'] == true,
              color: AppTheme.colorFFE67E22,
            ),
            _alertChip(
              label: 'Cold Chain Variance',
              active: healthAlerts['coldChainVariance'] == true,
              color: AppTheme.colorFF3498DB,
            ),
            _alertChip(
              label: 'Humidity Alert',
              active: healthAlerts['humidityAlert'] == true,
              color: AppTheme.colorFF16A085,
            ),
            _alertChip(
              label: 'Cooling Alert',
              active: healthAlerts['coolingAlert'] == true,
              color: AppTheme.colorFF8E44AD,
            ),
          ],
        ),
        const SizedBox(height: 18),
        _subhead('Recent Exceptions', isDark),
        const SizedBox(height: 10),
        if (exceptions.isEmpty)
          _emptyText(
            isDark,
            'No recent Geotab exception events for this asset.',
          )
        else
          ...exceptions.map(
            (entry) => _eventRow(isDark, entry, isFault: false),
          ),
        const SizedBox(height: 18),
        _subhead('Recent Faults', isDark),
        const SizedBox(height: 10),
        if (faults.isEmpty)
          _emptyText(isDark, 'No recent Geotab fault data for this asset.')
        else
          ...faults.map((entry) => _eventRow(isDark, entry, isFault: true)),
      ],
    );
  }

  Widget _eventRow(
    bool isDark,
    Map<String, dynamic> entry, {
    required bool isFault,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171C26 : AppTheme.colorFFF8FAFB,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isFault ? Icons.error_outline_rounded : Icons.warning_amber_rounded,
            color: isFault ? AppTheme.colorFFE74C3C : AppTheme.colorFFF39C12,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _string(
                    entry['name'],
                    fallback: isFault ? 'Fault' : 'Exception',
                  ),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF243447,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isFault
                      ? '${_string(entry['severity'], fallback: 'Unknown severity')} - ${_string(entry['failureMode'], fallback: 'Unknown mode')}'
                      : '${_string(entry['state'], fallback: 'Unknown state')} - Count ${_intValue(entry['count'])}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _string(entry['dateTime'], fallback: 'No timestamp'),
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.gray500 : AppTheme.gray500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required bool isDark,
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF121923 : AppTheme.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.05),
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.black.withValues(alpha: isDark ? 0.16 : 0.04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.colorFF4B7BE5, size: 20),
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppTheme.white : AppTheme.colorFF243447,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  Widget _metricTile({
    required bool isDark,
    required String label,
    required String value,
    String? suffix,
    required IconData icon,
    required Color accent,
    String? helperText,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [AppTheme.colorFF171F2B, AppTheme.colorFF0F1520]
              : [AppTheme.white, AppTheme.colorFFF8FBFF],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            suffix != null && value != 'N/A' ? '$value $suffix' : value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: isDark ? AppTheme.white : AppTheme.colorFF243447,
            ),
          ),
          if (helperText != null && helperText.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              helperText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.gray500 : AppTheme.gray500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoPill(bool isDark, String label, String value, {Color? accent}) {
    return Container(
      constraints: const BoxConstraints(minWidth: 180),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171C26 : AppTheme.colorFFF8FAFB,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.05),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray400 : AppTheme.gray600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color:
                  accent ?? (isDark ? AppTheme.white : AppTheme.colorFF243447),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _alertChip({
    required String label,
    required bool active,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: active
            ? color.withValues(alpha: 0.14)
            : color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? color.withValues(alpha: 0.3) : AppTheme.transparent,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: active ? color : color.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _subhead(String text, bool isDark) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: isDark ? AppTheme.gray300 : AppTheme.colorFF243447,
      ),
    );
  }

  Widget _emptyText(bool isDark, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        color: isDark ? AppTheme.gray400 : AppTheme.gray600,
      ),
    );
  }

  Color _healthColor(String status) {
    switch (status) {
      case 'offline':
        return AppTheme.colorFFE74C3C;
      case 'critical':
        return AppTheme.colorFFE67E22;
      case 'warning':
        return AppTheme.colorFFF39C12;
      default:
        return AppTheme.colorFF2ECC71;
    }
  }

  Widget _buildHistorySection(bool isDark) {
    final maintenance = _listOfMaps(_view['maintenanceHistory']);
    final fuel = _listOfMaps(_view['fuelConsumptionHistory']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _subhead('Maintenance history', isDark),
        const SizedBox(height: 10),
        if (maintenance.isEmpty)
          _emptyText(isDark, 'No maintenance history recorded yet.')
        else
          ...maintenance
              .take(5)
              .map(
                (row) => _historyRow(
                  isDark,
                  icon: Icons.build_circle_rounded,
                  title: _string(
                    row['type'] ?? row['description'],
                    fallback: 'Maintenance',
                  ),
                  subtitle: _string(
                    row['dateTime'] ?? row['recordedAt'] ?? row['date'],
                    fallback: 'N/A',
                  ),
                  trailing: _string(row['status'], fallback: 'Recorded'),
                ),
              ),
        const SizedBox(height: 16),
        _subhead('Fuel consumption history', isDark),
        const SizedBox(height: 10),
        if (fuel.isEmpty)
          _emptyText(isDark, 'No fuel history recorded yet.')
        else
          ...fuel
              .take(5)
              .map(
                (row) => _historyRow(
                  isDark,
                  icon: Icons.local_gas_station_rounded,
                  title: _string(row['station'], fallback: 'Fuel event'),
                  subtitle: _string(
                    row['dateTime'] ?? row['date'],
                    fallback: 'N/A',
                  ),
                  trailing: _string(
                    row['liters'] ?? row['volumeLiters'],
                    fallback: 'N/A',
                  ),
                ),
              ),
      ],
    );
  }

  Widget _historyRow(
    bool isDark, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.colorFF171C26 : AppTheme.colorFFF8FAFB,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.06)
              : AppTheme.black.withValues(alpha: 0.05),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.colorFF4B7BE5, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.white : AppTheme.colorFF243447,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppTheme.gray400 : AppTheme.gray600,
                  ),
                ),
              ],
            ),
          ),
          Text(
            trailing,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isDark ? AppTheme.gray300 : AppTheme.gray700,
            ),
          ),
        ],
      ),
    );
  }

  String _expiryLabel(dynamic value) {
    final text = _string(value, fallback: 'N/A');
    if (text == 'N/A') {
      return text;
    }
    final date = DateTime.tryParse(text);
    if (date == null) {
      return text;
    }
    final days = date.difference(DateTime.now()).inDays;
    if (days < 0) {
      return '$text - expired';
    }
    return '$text - ${days}d';
  }

  Color _expiryColor(dynamic value) {
    final days = int.tryParse(value?.toString() ?? '');
    if (days != null && days <= 30) {
      return AppTheme.colorFFE74C3C;
    }
    return AppTheme.colorFF2ECC71;
  }

  IconData _diagnosticIcon(String alias) {
    switch (alias) {
      case 'fuelLevel':
      case 'fuelTankCapacity':
        return Icons.local_gas_station_rounded;
      case 'engineCoolantTemperature':
      case 'outsideTemperature':
        return Icons.thermostat_rounded;
      case 'relativeHumidity':
        return Icons.water_drop_rounded;
      case 'engineCoolingFanSpeed':
        return Icons.toys_rounded;
      case 'batteryVoltage':
        return Icons.battery_charging_full_rounded;
      default:
        return Icons.speed_rounded;
    }
  }

  Color _diagnosticColor(String alias) {
    switch (alias) {
      case 'fuelLevel':
        return AppTheme.colorFFF39C12;
      case 'fuelTankCapacity':
        return AppTheme.colorFFFFB84D;
      case 'engineCoolantTemperature':
        return AppTheme.colorFFE67E22;
      case 'outsideTemperature':
        return AppTheme.colorFF3498DB;
      case 'relativeHumidity':
        return AppTheme.colorFF16A085;
      case 'engineCoolingFanSpeed':
        return AppTheme.colorFF8E44AD;
      case 'batteryVoltage':
        return AppTheme.colorFF2ECC71;
      default:
        return AppTheme.colorFF4B7BE5;
    }
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) {
      return {};
    }

    return value.map((key, val) => MapEntry(key.toString(), val));
  }

  List<Map<String, dynamic>> _listOfMaps(dynamic value) {
    if (value is! List) {
      return const [];
    }

    return value
        .whereType<Map>()
        .map((entry) => entry.map((key, val) => MapEntry(key.toString(), val)))
        .cast<Map<String, dynamic>>()
        .toList();
  }

  List<String> _list(dynamic value) {
    if (value is! List) {
      return const [];
    }

    return value
        .map((entry) => entry?.toString().trim() ?? '')
        .where((entry) => entry.isNotEmpty)
        .toList();
  }

  String _string(dynamic value, {String fallback = ''}) {
    final text = formatValue(value);
    if (text == 'N/A') {
      return fallback.isEmpty ? 'N/A' : fallback;
    }
    return text;
  }

  int _intValue(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _doubleValue(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _formatted(double value) {
    if (value <= 0) {
      return 'N/A';
    }

    return value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  }

  String _formattedPercent(double value) {
    if (value <= 0) {
      return 'N/A';
    }

    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)}%';
  }
}
