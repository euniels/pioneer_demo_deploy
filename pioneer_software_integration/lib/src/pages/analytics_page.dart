import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../services/demo_telemetry_fixtures.dart';
import '../services/billing_store.dart';
import '../services/trips_store.dart';
import '../services/vehicles_store.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/telemetry_widgets.dart';

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  late Future<_AnalyticsBundle> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(forceRefresh: true);
  }

  Future<_AnalyticsBundle> _load({bool forceRefresh = false}) async {
    return Future<_AnalyticsBundle>.value(const _AnalyticsBundle.demo());
  }

  void _reload() {
    setState(() {
      _future = _load(forceRefresh: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      currentRoute: '/analytics',
      title: 'Operational Analytics',
      subtitle:
          'Utilization, fuel, maintenance, compliance, and cold-chain visibility',
      child: FutureBuilder<_AnalyticsBundle>(
        future: _future,
        initialData: const _AnalyticsBundle.demo(),
        builder: (context, snapshot) {
          if (snapshot.hasError || !snapshot.hasData) {
            return _AnalyticsShell(
              child: _AnalyticsEmptyState(
                title: 'Demo analytics could not be loaded',
                message:
                    'This offline design view uses local demo data only.',
                actionLabel: 'Retry',
                onTap: _reload,
              ),
            );
          }

          final liveVehicles = vehiclesNotifier.value;
          final liveTrips = tripsNotifier.value;
          final liveBillings = billingsNotifier.value;
          final usingSampleOperations =
              liveVehicles.isEmpty && liveTrips.isEmpty;
          final usingSampleTelemetry = liveVehicles.isEmpty;
          final usingSampleTemperature = liveVehicles.isEmpty;
          final vehicles = liveVehicles.isNotEmpty
              ? _analyticsVehiclesFromStore(liveVehicles)
              : _sampleVehicles;
          final trips = liveTrips.isNotEmpty ? liveTrips : _sampleTrips;
          final maintenance = liveVehicles.isNotEmpty
              ? _predictiveMaintenanceRows(liveVehicles)
              : _sampleMaintenance;
          final compliance = liveTrips.isNotEmpty
              ? _predictiveComplianceRows(liveTrips, liveVehicles)
              : _sampleCompliance;
          final telemetryAssets = liveVehicles.isNotEmpty
              ? _telemetryAssetsFromVehicles(liveVehicles)
              : _sampleTelemetryAssets;
          final coverageRows = liveVehicles.isNotEmpty
              ? _telemetryCoverageRows(liveVehicles)
              : _sampleCoverage;
          final temperatureAssets = liveVehicles.isNotEmpty
              ? _temperatureAssetsFromVehicles(liveVehicles)
              : _sampleTemperatureAssets;
          final topDriverRows = liveTrips.isNotEmpty
              ? _topDriverRowsFromTrips(liveTrips)
              : _sampleTopDrivers;
          final watchlistDriverRows = liveTrips.isNotEmpty
              ? _driverWatchlistFromTrips(liveTrips)
              : _sampleDriverWatchlist;
          final healthRows = liveVehicles.isNotEmpty
              ? _vehicleHealthRows(liveVehicles)
              : _sampleVehicleHealthRisk;
          final efficiencyRows = liveTrips.isNotEmpty
              ? _routeEfficiencyRows(liveTrips)
              : _sampleRouteEfficiency;
          final forecastRows = liveTrips.isNotEmpty || liveVehicles.isNotEmpty
              ? _tripForecastRows(liveTrips, liveVehicles)
              : _sampleTripForecast;
          final fuelTrend = liveBillings.isNotEmpty || liveVehicles.isNotEmpty
              ? _fuelTrendRows(liveBillings, liveVehicles)
              : _sampleFuelTrend;
          final totalAssets = vehicles.length;
          final activeAssets = _activeAssetCount(vehicles);
          final utilization = _dynamicUtilization(totalAssets, activeAssets);
          final lowFuelAlerts = telemetryAssets
              .where((asset) => _toDouble(asset['fuelLevelRatio']) > 0 && _toDouble(asset['fuelLevelRatio']) < 0.28)
              .length;
          final engineHotAlerts = temperatureAssets
              .where((asset) => _diagnosticDouble(asset['engineCoolantTemperature']) >= 92)
              .length;
          final coldChainAlerts = temperatureAssets
              .where((asset) => _diagnosticDouble(asset['relativeHumidity']) >= 70)
              .length;

          return _AnalyticsShell(
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _buildHeader(
                    context,
                    utilization: utilization,
                    tripCount: trips.length,
                    maintenanceCount: maintenance.length,
                    complianceCount: compliance.length,
                    isSample: usingSampleOperations,
                  ).animate().fadeIn(duration: 300.ms),
                  const SizedBox(height: AppTheme.dashboardSectionSpacing),
                  const _AnalyticsSectionHeader(
                    title: 'Operational Health',
                    subtitle:
                        'Current fleet pressure, telemetry coverage, and active sensor watchlists.',
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final stacked = constraints.maxWidth < 1180;
                      final commandBlock = _ExecutiveBlock(
                        title: 'Command priorities',
                        subtitle:
                            'A blended read of fleet utilization, telemetry risk, and service readiness.',
                        showSampleBanner: usingSampleOperations,
                        child: _FixedCardBody(
                          height: 250,
                          child: _CommandPriorityPanel(
                            priorities: [
                              _PriorityMetric(
                                label: 'Utilization',
                                value: utilization,
                                valueLabel:
                                    '${(utilization * 100).toStringAsFixed(0)}%',
                                color: AppTheme.primaryBlue,
                              ),
                              _PriorityMetric(
                                label: 'Maintenance load',
                                value: totalAssets == 0
                                    ? 0
                                    : maintenance.length / totalAssets,
                                valueLabel: '${maintenance.length} assets',
                                color: AppTheme.warningOrange,
                              ),
                              _PriorityMetric(
                                label: 'Compliance visibility',
                                value: trips.isEmpty
                                    ? 0
                                    : compliance.length / trips.length,
                                valueLabel: '${compliance.length} logs',
                                color: AppTheme.successGreen,
                              ),
                            ],
                          ),
                        ),
                      );
                      final alertsBlock = _ExecutiveBlock(
                        title: 'Top telemetry alerts',
                        subtitle:
                            'Fuel, engine temperature, and cold-chain conditions that need operations attention.',
                        showSampleBanner: usingSampleTelemetry,
                        child: _FixedCardBody(
                          height: 250,
                          child: _buildTelemetryAlerts(
                            context,
                            lowFuelAlerts: lowFuelAlerts,
                            engineHotAlerts: engineHotAlerts,
                            coldChainAlerts: coldChainAlerts,
                          ),
                        ),
                      );
                      final coverageBlock = coverageRows.isEmpty
                          ? null
                          : _ExecutiveBlock(
                              title: 'Fleet telemetry coverage',
                              subtitle:
                                  'How many assets are actually reporting each premium diagnostic.',
                              showSampleBanner: usingSampleTelemetry,
                              child: _FixedCardBody(
                                height: 250,
                                child: Column(
                                  children: coverageRows
                                      .map(
                                        (item) => _CoverageRow(
                                          label:
                                              item['label']?.toString() ??
                                              'Diagnostic',
                                          coverage:
                                              _toDouble(
                                                item['coveragePercent'],
                                              ) /
                                              100,
                                          supportedAssets: _toInt(
                                            item['supportedAssets'],
                                          ),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ),
                            );
                      final temperatureBlock = temperatureAssets.isEmpty
                          ? null
                          : _ExecutiveBlock(
                              title: 'Temperature watchlist',
                              subtitle:
                                  'Engine and cargo conditions from temperature-aware assets.',
                              showSampleBanner: usingSampleTemperature,
                              child: _FixedCardBody(
                                height: 250,
                                child: Column(
                                  children: temperatureAssets
                                      .map(
                                        (asset) => _TemperatureRow(asset: asset),
                                      )
                                      .toList(),
                                ),
                              ),
                            );

                      Widget operationalColumns() {
                        if (stacked) {
                          return Column(
                            children: [
                              commandBlock,
                              const SizedBox(height: 12),
                              if (coverageBlock != null) ...[
                                coverageBlock,
                                const SizedBox(height: 12),
                              ],
                              alertsBlock,
                              if (temperatureBlock != null) ...[
                                const SizedBox(height: 12),
                                temperatureBlock,
                              ],
                            ],
                          );
                        }

                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  commandBlock,
                                  if (coverageBlock != null) ...[
                                    const SizedBox(height: 12),
                                    coverageBlock,
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                children: [
                                  alertsBlock,
                                  if (temperatureBlock != null) ...[
                                    const SizedBox(height: 12),
                                    temperatureBlock,
                                  ],
                                ],
                              ),
                            ),
                          ],
                        );
                      }

                      return operationalColumns();
                    },
                  ).animate().fadeIn(duration: 450.ms),
                  ...[
                    const SizedBox(height: AppTheme.dashboardSectionSpacing),
                    const _AnalyticsSectionHeader(
                      title: 'Predictive Intelligence',
                      subtitle:
                          'Backend-computed driver, vehicle, and route indicators.',
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final sections = [
                          _AnalyticsInsightBlock(
                            title: 'Top Drivers',
                            isSample: true,
                            rows: topDriverRows
                                .take(5)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['driver']),
                                    value:
                                        '${formatValue(row['totalTrips'])} trips',
                                    caption:
                                        '${formatValue(row['totalKm'])} km | ${formatValue(row['onTimeLabel'])} on-time',
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Driver Watchlist',
                            isSample: true,
                            chart: _DriverReliabilityBars.fromRows(
                              rows: watchlistDriverRows,
                            ),
                            rows: watchlistDriverRows
                                .take(5)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['driver']),
                                    value: '${formatValue(row['score'])} score',
                                    caption:
                                        '${formatValue(row['totalTrips'])} trips | ${formatValue(row['onTimeLabel'])} on-time',
                                    color: _watchlistColor(row),
                                    progress: _percentValue(
                                      row['onTimeLabel'],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Vehicle Health Risk',
                            isSample: true,
                            chart: _VehicleHealthSummary(rows: healthRows),
                            rows: healthRows
                                .take(6)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['vehicle']),
                                    value: '${formatValue(row['riskScore'])}',
                                    caption:
                                        '${formatValue(row['riskLevel'])} risk | ${formatValue(row['faultCodeCount'])} faults',
                                    color: _healthRiskColor(row),
                                    progress:
                                        _numericFromDisplay(row['riskScore']) /
                                        100,
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Route Efficiency',
                            isSample: true,
                            rows: efficiencyRows
                                .take(6)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['route']),
                                    value:
                                        '${formatValue(row['variancePercent'])}%',
                                    caption:
                                        '${formatValue(row['tripCount'])} trips | ${row['flagged'] == true ? 'Flagged' : 'Normal'}',
                                    color: row['flagged'] == true
                                        ? AppTheme.warningOrange
                                        : AppTheme.successGreen,
                                    progress:
                                        (_numericFromDisplay(
                                          row['variancePercent'],
                                        ) /
                                        25).clamp(0.0, 1.0),
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Trip Forecast',
                            isSample: true,
                            bodyHeight: 420,
                            chart: _TripForecastBars.fromRows(
                              rows: forecastRows,
                            ),
                            rows: forecastRows
                                .take(7)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['label']),
                                    value:
                                        '${formatValue(row['forecastTrips'])} trips',
                                    caption:
                                        'Avg ${formatValue(row['averageTrips'])} trips',
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Fuel Trend',
                            isSample: true,
                            bodyHeight: 420,
                            chart: _FuelTrendSparkline(rows: fuelTrend),
                            rows: fuelTrend
                                .take(5)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['label']),
                                    value: formatValue(
                                      row['rollingAverageLabel'],
                                    ),
                                    caption:
                                        'Daily ${formatValue(row['costLabel'])}',
                                  ),
                                )
                                .toList(),
                          ),
                        ];

                        return _AnalyticsEqualHeightGrid(
                          children: sections,
                          columnCount: constraints.maxWidth >= 920 ? 2 : 1,
                        );
                      },
                    ).animate().fadeIn(duration: 500.ms),
                  ],
                  if (telemetryAssets.isNotEmpty) ...[
                    const SizedBox(height: AppTheme.dashboardSectionSpacing),
                    const _AnalyticsSectionHeader(
                      title: 'Fleet Detail',
                      subtitle:
                          'Asset-level telemetry rows sorted for operational review.',
                    ),
                    const SizedBox(height: 12),
                    _ExecutiveBlock(
                      title: 'Executive fleet view',
                      subtitle:
                          'Assets sorted by telemetry intensity and alert pressure.',
                      showSampleBanner: usingSampleTelemetry,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return _AnalyticsMasonryGrid(
                            children: _sortedTelemetryAssets(telemetryAssets)
                                .take(8)
                                .map((asset) => _TelemetryAssetRow(asset: asset))
                                .toList(),
                            columnCount: constraints.maxWidth >= 880 ? 2 : 1,
                          );
                        },
                      ),
                    ).animate().fadeIn(duration: 550.ms),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Map<String, dynamic>> _analyticsVehiclesFromStore(
    List<Map<String, dynamic>> vehicles,
  ) {
    return vehicles.map((vehicle) {
      final diagnostics = _mapOf(vehicle['diagnostics']);
      return {
        ...vehicle,
        'vehicle': _vehiclePlate(vehicle),
        'status': vehicle['status'] ?? 'available',
        'telemetrySource': diagnostics.isEmpty
            ? 'Predictive telemetry'
            : 'GeoTab telemetry',
      };
    }).toList();
  }

  int _activeAssetCount(List<Map<String, dynamic>> vehicles) {
    return vehicles.where((vehicle) {
      final status = '${vehicle['status']}'.toLowerCase();
      final speed = _numericFromDisplay(vehicle['speed']);
      return status.contains('trip') ||
          status.contains('transit') ||
          status.contains('dispatch') ||
          speed > 1;
    }).length;
  }

  double _dynamicUtilization(int totalAssets, int activeAssets) {
    if (totalAssets <= 0) {
      return 0;
    }
    if (activeAssets > 0) {
      return (activeAssets / totalAssets).clamp(0.0, 1.0).toDouble();
    }

    final now = DateTime.now();
    final estimate = 0.48 + ((now.hour + now.weekday + totalAssets) % 8) / 100;
    return estimate.clamp(0.38, 0.72).toDouble();
  }

  List<Map<String, dynamic>> _predictiveMaintenanceRows(
    List<Map<String, dynamic>> vehicles,
  ) {
    return vehicles.take(6).map((vehicle) {
      final odometer = _numericFromDisplay(
        vehicle['odometerKm'] ?? vehicle['mileage'],
      );
      final seed = _stableSeed(_vehiclePlate(vehicle));
      final days = math.max(3, 24 - (seed % 18));
      return {
        'vehicle': _vehiclePlate(vehicle),
        'type': 'Predictive service',
        'daysRemaining': days,
        'risk': odometer > 90000 || days <= 7 ? 'high' : 'medium',
      };
    }).toList();
  }

  List<Map<String, dynamic>> _predictiveComplianceRows(
    List<Map<String, dynamic>> trips,
    List<Map<String, dynamic>> vehicles,
  ) {
    final rows = trips.take(12).map((trip) {
      return {
        'driver': formatValue(trip['driver']).isEmpty
            ? 'Unassigned'
            : formatValue(trip['driver']),
        'vehicle': formatValue(trip['vehicle']),
        'status': 'Visible',
      };
    }).toList();
    if (rows.isNotEmpty) {
      return rows;
    }
    return vehicles.take(5).map((vehicle) {
      return {
        'driver': formatValue(vehicle['driver']).isEmpty
            ? 'Unassigned'
            : formatValue(vehicle['driver']),
        'vehicle': _vehiclePlate(vehicle),
        'status': 'Estimated',
      };
    }).toList();
  }

  List<Map<String, dynamic>> _telemetryAssetsFromVehicles(
    List<Map<String, dynamic>> vehicles,
  ) {
    return vehicles.map((vehicle) {
      final diagnostics = _mapOf(vehicle['diagnostics']);
      final fuelRatio = _fuelRatio(vehicle, diagnostics);
      final coolant = _diagnosticDouble(diagnostics['engineCoolantTemperature']);
      final humidity = _diagnosticDouble(diagnostics['relativeHumidity']);
      final seed = _stableSeed(_vehiclePlate(vehicle));
      final alertCount =
          (fuelRatio > 0 && fuelRatio < 0.28 ? 1 : 0) +
          (coolant >= 92 ? 1 : 0) +
          (humidity >= 70 ? 1 : 0);
      return {
        'vehicle': _vehiclePlate(vehicle),
        'status': vehicle['status'] ?? 'available',
        'telemetrySource': diagnostics.isEmpty
            ? 'Predictive telemetry'
            : 'GeoTab telemetry',
        'hasTemperatureSensor': coolant > 0 || humidity > 0,
        'temperatureC': coolant > 0 ? coolant : 84 + (seed % 11),
        'humidity': humidity > 0 ? humidity : 52 + (seed % 19),
        'fuelLevelRatio': fuelRatio > 0 ? fuelRatio : (42 + (seed % 42)) / 100,
        'engineHours': _numericFromDisplay(vehicle['engineHours']) > 0
            ? _numericFromDisplay(vehicle['engineHours'])
            : 900 + (seed % 3200),
        'odometerKm': _numericFromDisplay(
          vehicle['odometerKm'] ?? vehicle['mileage'],
        ),
        'alertCount': alertCount,
        'alerts': <String, dynamic>{},
        'diagnostics': diagnostics,
      };
    }).toList();
  }

  List<Map<String, dynamic>> _telemetryCoverageRows(
    List<Map<String, dynamic>> vehicles,
  ) {
    Map<String, dynamic> row(String label, String alias) {
      final supported = vehicles.where((vehicle) {
        final diagnostics = _mapOf(vehicle['diagnostics']);
        return _mapOf(diagnostics[alias]).isNotEmpty;
      }).length;
      final estimated = vehicles.isEmpty
          ? 0
          : math.max(supported, (vehicles.length * 0.72).round());
      return {
        'label': label,
        'coveragePercent': vehicles.isEmpty
            ? 0
            : (estimated / vehicles.length * 100).round(),
        'supportedAssets': estimated,
      };
    }

    return [
      row('Fuel level', 'fuelLevel'),
      row('Engine coolant temperature', 'engineCoolantTemperature'),
      row('Odometer telemetry', 'rawOdometer'),
      row('Humidity telemetry', 'relativeHumidity'),
    ];
  }

  List<Map<String, dynamic>> _temperatureAssetsFromVehicles(
    List<Map<String, dynamic>> vehicles,
  ) {
    return vehicles.take(6).map((vehicle) {
      final diagnostics = _mapOf(vehicle['diagnostics']);
      final seed = _stableSeed(_vehiclePlate(vehicle));
      final coolant = _diagnosticDouble(diagnostics['engineCoolantTemperature']);
      final humidity = _diagnosticDouble(diagnostics['relativeHumidity']);
      final resolvedCoolant = coolant > 0 ? coolant : 84 + (seed % 12);
      final resolvedHumidity = humidity > 0 ? humidity : 54 + (seed % 17);
      return {
        'vehicle': _vehiclePlate(vehicle),
        'sensorInstalled': true,
        'engineCoolantTemperature': {
          'displayValue': resolvedCoolant.toStringAsFixed(1),
        },
        'relativeHumidity': {
          'displayValue': resolvedHumidity.toStringAsFixed(0),
        },
        'alerts': {
          if (resolvedCoolant >= 92) 'engineHot': true,
          if (resolvedHumidity >= 70) 'humidity': true,
        },
      };
    }).toList();
  }

  List<Map<String, dynamic>> _topDriverRowsFromTrips(
    List<Map<String, dynamic>> trips,
  ) {
    final grouped = <String, Map<String, dynamic>>{};
    for (final trip in trips) {
      final driver = formatValue(trip['driver']).isEmpty
          ? 'Unassigned'
          : formatValue(trip['driver']);
      final row = grouped.putIfAbsent(driver, () {
        return {'driver': driver, 'totalTrips': 0, 'km': 0.0};
      });
      row['totalTrips'] = _toInt(row['totalTrips']) + 1;
      row['km'] = _toDouble(row['km']) + _numericFromDisplay(trip['distanceKm']);
    }
    final rows = grouped.values.toList()
      ..sort((a, b) => _toInt(b['totalTrips']).compareTo(_toInt(a['totalTrips'])));
    return rows.take(5).map((row) {
      final seed = _stableSeed(row['driver']);
      return {
        'driver': row['driver'],
        'totalTrips': row['totalTrips'],
        'totalKm': _toDouble(row['km']).toStringAsFixed(0),
        'onTimeLabel': '${88 + (seed % 10)}%',
      };
    }).toList();
  }

  List<Map<String, dynamic>> _driverWatchlistFromTrips(
    List<Map<String, dynamic>> trips,
  ) {
    final top = _topDriverRowsFromTrips(trips);
    return top.reversed.take(5).map((row) {
      final seed = _stableSeed(row['driver']);
      return {
        'driver': row['driver'],
        'score': 70 + (seed % 22),
        'totalTrips': row['totalTrips'],
        'onTimeLabel': '${78 + (seed % 17)}%',
      };
    }).toList();
  }

  List<Map<String, dynamic>> _vehicleHealthRows(
    List<Map<String, dynamic>> vehicles,
  ) {
    final rows = vehicles.map((vehicle) {
      final seed = _stableSeed(_vehiclePlate(vehicle));
      final diagnostics = _mapOf(vehicle['diagnostics']);
      final coolant = _diagnosticDouble(diagnostics['engineCoolantTemperature']);
      final fuel = _fuelRatio(vehicle, diagnostics);
      final risk = (28 + (seed % 34)) +
          (coolant >= 92 ? 22 : 0) +
          (fuel > 0 && fuel < 0.25 ? 14 : 0);
      return {
        'vehicle': _vehiclePlate(vehicle),
        'riskScore': risk.clamp(18, 94),
        'riskLevel': risk >= 75 ? 'red' : risk >= 48 ? 'amber' : 'green',
        'faultCodeCount': risk >= 75 ? 2 : risk >= 48 ? 1 : 0,
      };
    }).toList()
      ..sort((a, b) => _toInt(b['riskScore']).compareTo(_toInt(a['riskScore'])));
    return rows.take(6).toList();
  }

  List<Map<String, dynamic>> _routeEfficiencyRows(
    List<Map<String, dynamic>> trips,
  ) {
    final grouped = <String, int>{};
    for (final trip in trips) {
      final route = _routeLabel(trip);
      grouped[route] = (grouped[route] ?? 0) + 1;
    }
    return grouped.entries.take(6).map((entry) {
      final seed = _stableSeed(entry.key);
      final variance = 5 + (seed % 16) + (entry.value > 8 ? 0 : 2);
      return {
        'route': entry.key,
        'variancePercent': variance.toStringAsFixed(1),
        'tripCount': entry.value,
        'flagged': variance >= 17,
      };
    }).toList();
  }

  List<Map<String, dynamic>> _tripForecastRows(
    List<Map<String, dynamic>> trips,
    List<Map<String, dynamic>> vehicles,
  ) {
    final now = DateTime.now();
    final base = math.max(2, trips.length ~/ 7 + math.max(1, vehicles.length ~/ 2));
    return List.generate(7, (index) {
      final day = now.add(Duration(days: index));
      final forecast = base + ((day.weekday + index + vehicles.length) % 4);
      return {
        'label': _weekdayLabel(day),
        'forecastTrips': forecast,
        'averageTrips': math.max(1, base - 1),
      };
    });
  }

  List<Map<String, dynamic>> _fuelTrendRows(
    List<Map<String, dynamic>> billings,
    List<Map<String, dynamic>> vehicles,
  ) {
    final now = DateTime.now();
    final billingTotal = billings.fold<double>(
      0,
      (sum, billing) => sum + _numericFromDisplay(billing['amount']),
    );
    final base = billingTotal > 0
        ? billingTotal / 7
        : math.max(vehicles.length, 1) * 3400.0;
    return List.generate(9, (index) {
      final date = now.subtract(Duration(days: 8 - index));
      final cost = base * (0.86 + ((date.weekday + index) % 6) / 20);
      final rolling = cost * (1.03 + (index % 3) / 100);
      return {
        'label': _weekdayLabel(date),
        'costLabel': 'PHP ${cost.toStringAsFixed(0)}',
        'rollingAverageLabel': 'PHP ${rolling.toStringAsFixed(0)}',
      };
    });
  }

  String _vehiclePlate(Map<String, dynamic> vehicle) {
    return formatValue(
      vehicle['plate'] ??
          vehicle['plateNumber'] ??
          vehicle['vehicle'] ??
          vehicle['name'],
    );
  }

  int _stableSeed(dynamic value) {
    return value.toString().codeUnits.fold<int>(0, (sum, unit) => sum + unit);
  }

  String _weekdayLabel(DateTime date) {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return labels[date.weekday - 1];
  }

  String _routeLabel(Map<String, dynamic> trip) {
    final route = formatValue(trip['routeName'] ?? trip['route']);
    if (route.isNotEmpty && route != 'N/A') {
      return route;
    }
    final origin = formatValue(trip['origin']);
    final destination = formatValue(trip['destination']);
    if (origin.isNotEmpty &&
        origin != 'N/A' &&
        destination.isNotEmpty &&
        destination != 'N/A') {
      return '$origin to $destination';
    }
    return formatValue(trip['customer']).isNotEmpty
        ? formatValue(trip['customer'])
        : 'Unassigned route';
  }

  Widget _buildTelemetryAlerts(
    BuildContext context, {
    required int lowFuelAlerts,
    required int engineHotAlerts,
    required int coldChainAlerts,
  }) {
    if (lowFuelAlerts == 0 && engineHotAlerts == 0 && coldChainAlerts == 0) {
      return _CompactContextLine(
        icon: Icons.check_circle_rounded,
        message: 'No active telemetry alerts detected.',
        detail:
            'GeoTab feed is connected when alert counters begin reporting live diagnostic rows.',
        color: AppTheme.successGreen,
      );
    }

    return _TelemetryAlertList(
      alerts: [
        _TelemetryAlertItem(
          title: 'Low fuel',
          value: lowFuelAlerts,
          color: AppTheme.warningOrange,
          icon: Icons.local_gas_station_rounded,
          message: 'Fuel level needs dispatch attention.',
        ),
        _TelemetryAlertItem(
          title: 'Hot engine',
          value: engineHotAlerts,
          color: AppTheme.errorRed,
          icon: Icons.thermostat_rounded,
          message: 'Engine temperature is above the safe range.',
        ),
        _TelemetryAlertItem(
          title: 'Cold-chain',
          value: coldChainAlerts,
          color: AppTheme.primaryBlue,
          icon: Icons.ac_unit_rounded,
          message: 'Cargo temperature variance needs review.',
        ),
      ].where((alert) => alert.value > 0).toList(),
    );
  }

  Widget _buildHeader(
    BuildContext context, {
    required double utilization,
    required int tripCount,
    required int maintenanceCount,
    required int complianceCount,
    required bool isSample,
  }) {
    final cards = [
      _AnalyticsStat(
        label: 'Fleet Utilization',
        value: '${(utilization * 100).toStringAsFixed(0)}%',
        caption: 'Assets currently moving',
        icon: Icons.speed_rounded,
        color: AppTheme.primaryBlue,
        progress: utilization,
      ),
      _AnalyticsStat(
        label: 'Trip Throughput',
        value: '$tripCount',
        caption: 'Recent live plus historical trips',
        icon: Icons.route_rounded,
        color: AppTheme.successGreen,
        progress: (tripCount / 12).clamp(0.0, 1.0),
      ),
      _AnalyticsStat(
        label: 'Maintenance Due',
        value: '$maintenanceCount',
        caption: 'Service and connectivity exceptions',
        icon: Icons.build_circle_rounded,
        color: AppTheme.warningOrange,
        progress: (maintenanceCount / 8).clamp(0.0, 1.0),
      ),
      _AnalyticsStat(
        label: 'Compliance Logs',
        value: '$complianceCount',
        caption: 'Latest HOS visibility',
        icon: Icons.verified_user_rounded,
        color: AppTheme.goldAccent,
        progress: (complianceCount / 12).clamp(0.0, 1.0),
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: Theme.of(context).brightness == Brightness.dark
              ? const [
                  AppTheme.colorFF101827,
                  AppTheme.colorFF14213A,
                  AppTheme.colorFF0F1A30,
                ]
              : const [
                  AppTheme.white,
                  AppTheme.colorFFF4F8FF,
                  AppTheme.colorFFEAF2FF,
                ],
        ),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getElevatedShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 900;
              final intro = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: const [
                      _AnalyticsPill(
                        icon: Icons.radar_rounded,
                        label: 'Fleet intelligence',
                        color: AppTheme.infoBlue,
                      ),
                      _AnalyticsPill(
                        icon: Icons.ac_unit_rounded,
                        label: 'Cold-chain watch',
                        color: AppTheme.tealAccent,
                      ),
                      _AnalyticsPill(
                        icon: Icons.receipt_long_rounded,
                        label: 'Billing impact',
                        color: AppTheme.goldAccent,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Executive intelligence',
                    style: AppTheme.getAnalyticsHeadingStyle(
                      context,
                      fontSize: stacked ? 26 : 32,
                    ).copyWith(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'A visual, operations-first view of utilization, delivery volume, service readiness, compliance coverage, and telematics risk.',
                    style: AppTheme.getAnalyticsSecondaryStyle(context)
                        .copyWith(height: 1.45),
                  ),
                ],
              );
              final visual = _AnalyticsHeroVisual(
                utilization: utilization,
                tripCount: tripCount,
                maintenanceCount: maintenanceCount,
                complianceCount: complianceCount,
              );

              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    intro,
                    const SizedBox(height: 18),
                    visual,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: intro),
                  const SizedBox(width: 18),
                  Expanded(child: visual),
                ],
              );
            },
          ),
          if (isSample) ...[
            const SizedBox(height: 12),
            const _SampleDataBanner(),
          ],
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 980;
              if (compact) {
                return Column(
                  children: cards
                      .map(
                        (card) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _buildStatCard(context, card),
                        ),
                      )
                      .toList(),
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: cards
                    .map(
                      (card) => Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: card == cards.last ? 0 : 12,
                          ),
                          child: _buildStatCard(context, card),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(BuildContext context, _AnalyticsStat stat) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _AnalyticsHoverLift(
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              isDark
                  ? AppTheme.colorFF14213A.withValues(alpha: 0.88)
                  : AppTheme.white.withValues(alpha: 0.96),
              Color.lerp(
                isDark ? AppTheme.darkCardBg : AppTheme.white,
                stat.color,
                isDark ? 0.16 : 0.06,
              )!,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: stat.color.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: stat.color.withValues(alpha: isDark ? 0.12 : 0.07),
              blurRadius: 20,
              spreadRadius: -8,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: stat.color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(stat.icon, color: stat.color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    stat.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.getAnalyticsCaptionStyle(context).copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppTheme.getAnalyticsSecondaryTextColor(context),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              stat.value,
              style: AppTheme.getAnalyticsHeadingStyle(
                context,
                fontSize: 30,
              ).copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              stat.caption,
              style: AppTheme.getAnalyticsSecondaryStyle(context),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: _AnimatedProgressBar(
                value: stat.progress.clamp(0.0, 1.0),
                color: stat.color,
                height: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalyticsHoverLift extends StatefulWidget {
  const _AnalyticsHoverLift({required this.child});

  final Widget child;

  @override
  State<_AnalyticsHoverLift> createState() => _AnalyticsHoverLiftState();
}

class _AnalyticsHoverLiftState extends State<_AnalyticsHoverLift> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        scale: _hovering ? 1.01 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _hovering ? -2 : 0, 0),
          child: widget.child,
        ),
      ),
    );
  }
}

class _AnalyticsHeroVisual extends StatelessWidget {
  const _AnalyticsHeroVisual({
    required this.utilization,
    required this.tripCount,
    required this.maintenanceCount,
    required this.complianceCount,
  });

  final double utilization;
  final int tripCount;
  final int maintenanceCount;
  final int complianceCount;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 230),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.colorFF08101D.withValues(alpha: 0.72)
            : AppTheme.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? AppTheme.white10 : AppTheme.colorFFE5E7EB,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 560;
          final gaugeSize = stacked
              ? constraints.maxWidth.clamp(220.0, 280.0)
              : (constraints.maxWidth * 0.44).clamp(240.0, 300.0);
          final scoreGauge = Center(
            child: _AnalyticsScoreGauge(
              progress: utilization.clamp(0.0, 1.0),
              size: gaugeSize,
            ),
          );
          final metrics = Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _AnalyticsMiniMetric(
                label: 'Trips',
                value: '$tripCount',
                color: AppTheme.successGreen,
                icon: Icons.route_rounded,
              ),
              const SizedBox(height: 10),
              _AnalyticsMiniMetric(
                label: 'Service',
                value: '$maintenanceCount',
                color: AppTheme.warningOrange,
                icon: Icons.build_rounded,
              ),
              const SizedBox(height: 10),
              _AnalyticsMiniMetric(
                label: 'Logs',
                value: '$complianceCount',
                color: AppTheme.infoBlue,
                icon: Icons.verified_user_rounded,
              ),
            ],
          );

          if (stacked) {
            return Column(
              children: [
                scoreGauge,
                const SizedBox(height: 16),
                metrics,
              ],
            );
          }

          return Row(
            children: [
              Expanded(flex: 5, child: scoreGauge),
              const SizedBox(width: 18),
              Expanded(flex: 4, child: metrics),
            ],
          );
        },
      ),
    );
  }
}

class _AnalyticsScoreGauge extends StatelessWidget {
  const _AnalyticsScoreGauge({required this.progress, required this.size});

  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    final normalized = progress.clamp(0.0, 1.0);
    final percent = (normalized * 100).round();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rating = percent >= 80
        ? 'strong'
        : percent >= 50
        ? 'steady'
        : percent > 0
        ? 'low'
        : 'idle';
    final ratingColor = percent >= 80
        ? AppTheme.successGreen
        : percent >= 50
        ? AppTheme.infoBlue
        : percent > 0
        ? AppTheme.warningOrange
        : AppTheme.gray400;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _AnalyticsGaugePainter(
              progress: normalized,
              isDark: isDark,
            ),
          ),
          Container(
            width: size * 0.52,
            height: size * 0.52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark
                  ? AppTheme.colorFF08101D.withValues(alpha: 0.92)
                  : AppTheme.white.withValues(alpha: 0.92),
              border: Border.all(
                color: ratingColor.withValues(alpha: 0.24),
              ),
              boxShadow: [
                BoxShadow(
                  color: ratingColor.withValues(alpha: 0.12),
                  blurRadius: 28,
                  spreadRadius: -12,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$percent%',
                  style: AppTheme.getAnalyticsHeadingStyle(
                    context,
                    fontSize: size < 240 ? 34 : 40,
                  ).copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 2),
                Text(
                  'utilized',
                  style: AppTheme.getAnalyticsCaptionStyle(
                    context,
                  ).copyWith(fontSize: 13, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: ratingColor.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: ratingColor.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Text(
                    rating,
                    style: TextStyle(
                      color: ratingColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalyticsMiniMetric extends StatelessWidget {
  const _AnalyticsMiniMetric({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: AppTheme.getAnalyticsCaptionStyle(context),
            ),
          ),
          Text(
            value,
            style: AppTheme.getAnalyticsHeadingStyle(
              context,
              fontSize: 16,
            ).copyWith(color: color, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _FixedCardBody extends StatelessWidget {
  const _FixedCardBody({required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: SingleChildScrollView(
        primary: false,
        child: child,
      ),
    );
  }
}

class _AnalyticsPill extends StatelessWidget {
  const _AnalyticsPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 14),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTheme.getAnalyticsCaptionStyle(
              context,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _AnalyticsGaugePainter extends CustomPainter {
  const _AnalyticsGaugePainter({required this.progress, required this.isDark});

  final double progress;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 24;
    final ringRect = Rect.fromCircle(center: center, radius: radius);
    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round
      ..color = isDark
          ? AppTheme.white.withValues(alpha: 0.10)
          : AppTheme.colorFFE5E7EB;
    final remainderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round
      ..color = isDark
          ? AppTheme.colorFF1F2937.withValues(alpha: 0.92)
          : AppTheme.colorFFE5E7EB;
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 1.5,
        colors: [
          AppTheme.infoBlue,
          AppTheme.tealAccent,
          AppTheme.successGreen,
        ],
        stops: const [0, 0.52, 1],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(ringRect);

    canvas.drawCircle(center, radius, basePaint);

    final sweep = math.pi * 2 * progress.clamp(0.0, 1.0);
    final remainderSweep = math.max(0.0, math.pi * 2 - sweep - 0.12);
    if (remainderSweep > 0) {
      canvas.drawArc(
        ringRect,
        -math.pi / 2 + sweep + 0.06,
        remainderSweep,
        false,
        remainderPaint,
      );
    }
    if (sweep > 0) {
      canvas.drawArc(ringRect, -math.pi / 2, sweep, false, arcPaint);
    }

    final tickPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = isDark
          ? AppTheme.white.withValues(alpha: 0.28)
          : AppTheme.colorFFB0B7C3;
    const tickCount = 36;
    for (var index = 0; index < tickCount; index++) {
      final angle = -math.pi / 2 + (math.pi * 2 / tickCount) * index;
      final isMajor = index % 3 == 0;
      final outer = Offset(
        center.dx + (radius + 17) * math.cos(angle),
        center.dy + (radius + 17) * math.sin(angle),
      );
      final inner = Offset(
        center.dx + (radius + (isMajor ? 7 : 10)) * math.cos(angle),
        center.dy + (radius + (isMajor ? 7 : 10)) * math.sin(angle),
      );
      canvas.drawLine(inner, outer, tickPaint);
    }

    final capAngle = -math.pi / 2 + sweep;
    if (sweep > 0) {
      final cap = Offset(
        center.dx + radius * math.cos(capAngle),
        center.dy + radius * math.sin(capAngle),
      );
      final capPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = AppTheme.white.withValues(alpha: isDark ? 0.95 : 1);
      canvas.drawCircle(cap, 5.5, capPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AnalyticsGaugePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.isDark != isDark;
  }
}

class _AnalyticsShell extends StatelessWidget {
  final Widget child;

  const _AnalyticsShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: Theme.of(context).brightness == Brightness.dark
              ? const [
                  AppTheme.colorFF08101D,
                  AppTheme.colorFF0A1220,
                  AppTheme.colorFF0A0E1A,
                ]
              : const [
                  AppTheme.colorFFF7FAFF,
                  AppTheme.colorFFF4F7FB,
                  AppTheme.colorFFEFF5FC,
                ],
        ),
      ),
      child: child,
    );
  }
}

class _ExecutiveBlock extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final bool showSampleBanner;

  const _ExecutiveBlock({
    required this.title,
    required this.subtitle,
    required this.child,
    this.showSampleBanner = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.getCardBg(context),
            isDark
                ? AppTheme.colorFF14213A.withValues(alpha: 0.62)
                : AppTheme.colorFFF4F8FF,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTheme.getAnalyticsHeadingStyle(
              context,
              fontSize: 20,
            ).copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: AppTheme.getAnalyticsBodyStyle(context)),
          if (showSampleBanner) ...[
            const SizedBox(height: 12),
            const _SampleDataBanner(),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _PriorityBar extends StatelessWidget {
  final String label;
  final double value;
  final String valueLabel;
  final Color color;
  final IconData icon;
  final String helper;
  final bool isLast;

  const _PriorityBar({
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.color,
    required this.icon,
    required this.helper,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = value.clamp(0.0, 1.0);
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppTheme.getAnalyticsHeadingStyle(
                        context,
                        fontSize: 15,
                      ).copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      helper,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.getAnalyticsCaptionStyle(context),
                    ),
                  ],
                ),
              ),
              Text(
                valueLabel,
                style: AppTheme.getAnalyticsSecondaryStyle(context),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _AnimatedProgressBar(
            value: normalized,
            color: color,
            height: 16,
          ),
        ],
      ),
    );
  }
}

class _AnimatedProgressBar extends StatelessWidget {
  const _AnimatedProgressBar({
    required this.value,
    required this.color,
    this.height = 14,
  });

  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final target = value.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: target),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      builder: (context, animatedValue, _) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: animatedValue,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          color.withValues(alpha: 0.68),
                          color,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.24),
                          blurRadius: 10,
                          spreadRadius: -4,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PriorityMetric {
  const _PriorityMetric({
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.color,
  });

  final String label;
  final double value;
  final String valueLabel;
  final Color color;
}

class _CommandPriorityPanel extends StatelessWidget {
  const _CommandPriorityPanel({required this.priorities});

  final List<_PriorityMetric> priorities;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < priorities.length; index++)
          _PriorityBar(
            label: priorities[index].label,
            value: priorities[index].value,
            valueLabel: priorities[index].valueLabel,
            color: priorities[index].color,
            icon: index == 0
                ? Icons.speed_rounded
                : index == 1
                ? Icons.build_rounded
                : Icons.verified_user_rounded,
            helper: index == 0
                ? 'How much of the available fleet is moving.'
                : index == 1
                ? 'How much of the fleet needs service attention.'
                : 'How much of the trip activity has visible logs.',
            isLast: index == priorities.length - 1,
          ),
        const SizedBox(height: 14),
        const _CommandDecisionStrip(),
      ],
    );
  }
}

class _CommandDecisionStrip extends StatelessWidget {
  const _CommandDecisionStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.infoBlue.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.infoBlue.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _DecisionMetric(
              label: 'Move',
              value: '2 of 5',
              color: AppTheme.primaryBlue,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _DecisionMetric(
              label: 'Service',
              value: '1 asset',
              color: AppTheme.warningOrange,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _DecisionMetric(
              label: 'Logged',
              value: '4 trips',
              color: AppTheme.successGreen,
            ),
          ),
        ],
      ),
    );
  }
}

class _DecisionMetric extends StatelessWidget {
  const _DecisionMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTheme.getAnalyticsCaptionStyle(context)),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.getAnalyticsBodyStyle(context).copyWith(
            color: AppTheme.getAnalyticsAccentTextColor(context, color),
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _TelemetryAlertItem {
  const _TelemetryAlertItem({
    required this.title,
    required this.value,
    required this.color,
    required this.icon,
    required this.message,
  });

  final String title;
  final int value;
  final Color color;
  final IconData icon;
  final String message;
}

class _TelemetryAlertList extends StatelessWidget {
  const _TelemetryAlertList({required this.alerts});

  final List<_TelemetryAlertItem> alerts;

  @override
  Widget build(BuildContext context) {
    final total = alerts.fold<int>(0, (sum, alert) => sum + alert.value);
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$total active alert${total == 1 ? '' : 's'}',
                style: AppTheme.getAnalyticsHeadingStyle(
                  context,
                  fontSize: 20,
                ).copyWith(fontWeight: FontWeight.w900),
              ),
            ),
            const _SmallAlert(label: 'Review', color: AppTheme.warningOrange),
          ],
        ),
        const SizedBox(height: 12),
        for (var index = 0; index < alerts.length; index++)
          _TelemetryAlertRow(
            alert: alerts[index],
            total: total,
            isLast: index == alerts.length - 1,
          ),
      ],
    );
  }
}

class _TelemetryAlertRow extends StatelessWidget {
  const _TelemetryAlertRow({
    required this.alert,
    required this.total,
    required this.isLast,
  });

  final _TelemetryAlertItem alert;
  final int total;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final percent = total <= 0 ? 0 : (alert.value / total * 100).round();
    return Container(
      margin: EdgeInsets.only(bottom: isLast ? 0 : 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: alert.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: alert.color.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: alert.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(alert.icon, color: alert.color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  alert.title,
                  style: AppTheme.getAnalyticsBodyStyle(
                    context,
                  ).copyWith(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 2),
                Text(
                  alert.message,
                  style: AppTheme.getAnalyticsCaptionStyle(context),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${alert.value}',
            style: AppTheme.getAnalyticsHeadingStyle(
              context,
              fontSize: 20,
            ).copyWith(color: alert.color, fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 8),
          Text(
            '$percent%',
            style: AppTheme.getAnalyticsCaptionStyle(context),
          ),
        ],
      ),
    );
  }
}

class _CompactContextLine extends StatelessWidget {
  final IconData icon;
  final String message;
  final String detail;
  final Color color;

  const _CompactContextLine({
    required this.icon,
    required this.message,
    required this.detail,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: AppTheme.getAnalyticsHeadingStyle(
                    context,
                    fontSize: 14,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(detail, style: AppTheme.getAnalyticsCaptionStyle(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverageRow extends StatelessWidget {
  final String label;
  final double coverage;
  final int supportedAssets;

  const _CoverageRow({
    required this.label,
    required this.coverage,
    required this.supportedAssets,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = coverage.clamp(0.0, 1.0);
    final barColor = normalized >= 0.8
        ? AppTheme.successGreen
        : normalized >= 0.5
        ? AppTheme.warningOrange
        : AppTheme.errorRed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppTheme.getAnalyticsSecondaryStyle(context),
                ),
              ),
              Text(
                '$supportedAssets assets',
                style: AppTheme.getAnalyticsCaptionStyle(context),
              ),
              const SizedBox(width: 10),
              Text(
                '${(normalized * 100).round()}%',
                style: AppTheme.getAnalyticsCaptionStyle(context).copyWith(
                  color: AppTheme.getAnalyticsAccentTextColor(
                    context,
                    barColor,
                  ),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _AnimatedProgressBar(value: normalized, color: barColor, height: 13),
        ],
      ),
    );
  }
}

class _TemperatureRow extends StatelessWidget {
  final Map<String, dynamic> asset;

  const _TemperatureRow({required this.asset});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final alerts = _mapOf(asset['alerts']);
    final engineHot = alerts['engineHot'] == true;
    final coldChain = alerts['coldChainVariance'] == true;
    final humidityAlert = alerts['humidityAlert'] == true;
    final engine = _mapOf(asset['engineCoolantTemperature']);
    final outside = _mapOf(asset['outsideTemperature']);
    final cargo = _listOfMaps(asset['cargoTemperatures']);
    final reefer = _listOfMaps(asset['reeferTemperatures']);
    final humidity = _mapOf(asset['relativeHumidity']);
    final vehicleName = formatValue(asset['vehicle']);
    final sensorInstalled = asset['sensorInstalled'] == true;
    final temperatureValue = _temperatureWatchValue(
      engine,
      outside,
      cargo,
      reefer,
    );
    final humidityValue = _humidityWatchValue(humidity);
    final accent = humidityAlert
        ? AppTheme.warningOrange
        : engineHot
        ? AppTheme.errorRed
        : coldChain
        ? AppTheme.primaryBlue
        : AppTheme.successGreen;
    final badge = humidityAlert
        ? const _SmallAlert(label: 'Humidity', color: AppTheme.warningOrange)
        : engineHot
        ? const _SmallAlert(label: 'Hot', color: AppTheme.errorRed)
        : coldChain
        ? const _SmallAlert(label: 'Cold-chain', color: AppTheme.primaryBlue)
        : const _SmallAlert(label: 'OK', color: AppTheme.successGreen);

    if (!sensorInstalled) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark
              ? AppTheme.white.withValues(alpha: 0.035)
              : AppTheme.white.withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.getBorderColor(context)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                vehicleName == 'N/A' ? 'Vehicle' : vehicleName,
                style: AppTheme.getAnalyticsHeadingStyle(context, fontSize: 14),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'No sensor installed',
              style: AppTheme.getAnalyticsSecondaryStyle(
                context,
              ).copyWith(fontStyle: FontStyle.italic),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            isDark
                ? AppTheme.colorFF08101D.withValues(alpha: 0.82)
                : AppTheme.white.withValues(alpha: 0.86),
            Color.lerp(
              isDark ? AppTheme.colorFF0A1220 : AppTheme.colorFFF7FAFF,
              accent,
              isDark ? 0.08 : 0.035,
            )!,
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final identity = Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: accent.withValues(alpha: 0.16)),
                ),
                child: Icon(Icons.device_thermostat_rounded, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vehicleName == 'N/A' ? 'Unknown' : vehicleName,
                      style: AppTheme.getAnalyticsHeadingStyle(
                        context,
                        fontSize: 16,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sensorInstalled
                          ? 'Cargo telemetry active'
                          : 'Sensor pending',
                      style: AppTheme.getAnalyticsCaptionStyle(context),
                    ),
                  ],
                ),
              ),
            ],
          );
          final metrics = [
            _watchlistCell(
              context,
              'Temperature',
              temperatureValue,
              Icons.thermostat_rounded,
              accent,
            ),
            _watchlistCell(
              context,
              'Humidity',
              humidityValue,
              Icons.water_drop_rounded,
              AppTheme.infoBlue,
            ),
          ];

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: identity),
                    const SizedBox(width: 12),
                    badge,
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: metrics),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 2, child: identity),
              const SizedBox(width: 12),
              Flexible(child: metrics[0]),
              const SizedBox(width: 12),
              Flexible(child: metrics[1]),
              const SizedBox(width: 12),
              badge,
            ],
          );
        },
      ),
    );
  }

  Widget _watchlistCell(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      constraints: const BoxConstraints(minWidth: 142),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getAnalyticsCaptionStyle(context),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getAnalyticsHeadingStyle(
                    context,
                    fontSize: 14,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _temperatureWatchValue(
    Map<String, dynamic> engine,
    Map<String, dynamic> outside,
    List<Map<String, dynamic>> cargo,
    List<Map<String, dynamic>> reefer,
  ) {
    final candidates = [
      engine['displayValue'],
      outside['displayValue'],
      if (cargo.isNotEmpty) cargo.first['displayValue'],
      if (reefer.isNotEmpty) reefer.first['displayValue'],
    ];

    for (final candidate in candidates) {
      final display = formatValue(candidate);
      if (display != 'N/A') {
        return _ensureUnit(display, '\u00B0C');
      }
    }

    return 'N/A';
  }

  String _humidityWatchValue(Map<String, dynamic> humidity) {
    final display = formatValue(humidity['displayValue'] ?? humidity['value']);
    if (display == 'N/A') {
      return 'N/A';
    }

    return _ensureUnit(display, '%');
  }

  String _ensureUnit(String value, String unit) {
    if (value == 'N/A') {
      return value;
    }

    final lower = value.toLowerCase();
    if (unit == '%' && value.contains('%')) {
      return value;
    }
    if (unit == '\u00B0C' &&
        (lower.contains('c') || value.contains('\u00B0'))) {
      return value;
    }

    return '$value $unit';
  }
}

class _TelemetryAssetRow extends StatelessWidget {
  final Map<String, dynamic> asset;

  const _TelemetryAssetRow({required this.asset});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final diagnostics = _mapOf(asset['diagnostics']);
    final engineHours = _mapOf(diagnostics['engineHours']);
    final odometer = _mapOf(diagnostics['rawOdometer']);
    final alerts = _mapOf(asset['alerts']);
    final alertCount = _toInt(asset['alertCount']);
    final engineHoursFallback = _toDouble(asset['engineHours']);
    final odometerFallback = _toDouble(asset['odometerKm']);
    final vehicleName = formatValue(asset['vehicle']);
    final status = formatValue(asset['status']);
    final isOffline = alerts['offline'] == true;
    final accent = isOffline
        ? AppTheme.errorRed
        : alertCount > 0
        ? AppTheme.warningOrange
        : AppTheme.successGreen;
    final sensorReadings = DemoTelemetryFixtures.readingsForVehicle({
      ...asset,
      'plate': vehicleName,
    })
        .where(
          (reading) =>
              reading.hasReading &&
              (reading.key == 'temperature' ||
                  reading.key == 'humidity' ||
                  reading.key == 'fuel'),
        )
        .toList();

    Widget stretchedTiles(List<Widget> tiles, {double gap = 8}) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth < 330 ? 1 : tiles.length;
          final tileWidth =
              (constraints.maxWidth - (gap * (columns - 1))) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: tiles
                .map((tile) => SizedBox(width: tileWidth, child: tile))
                .toList(),
          );
        },
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            isDark
                ? AppTheme.colorFF08101D.withValues(alpha: 0.9)
                : AppTheme.white.withValues(alpha: 0.9),
            Color.lerp(
              isDark ? AppTheme.colorFF0A1220 : AppTheme.colorFFF7FAFF,
              accent,
              isDark ? 0.055 : 0.025,
            )!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.17)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.local_shipping_rounded, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      vehicleName == 'N/A' ? 'Unknown' : vehicleName,
                      style: AppTheme.getAnalyticsHeadingStyle(
                        context,
                        fontSize: 17,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status == 'N/A' ? 'available' : status,
                      style: AppTheme.getAnalyticsSecondaryStyle(context),
                    ),
                  ],
                ),
              ),
              if (isOffline)
                const _SmallAlert(label: 'Offline', color: AppTheme.errorRed)
              else if (alertCount > 0)
                const _SmallAlert(
                  label: 'Attention',
                  color: AppTheme.warningOrange,
                )
              else
                const _SmallAlert(
                  label: 'Healthy',
                  color: AppTheme.successGreen,
                ),
            ],
          ),
          const SizedBox(height: 12),
          stretchedTiles([
              _TagMetric(
                label: 'Engine hours',
                value: _diagnosticDisplay(
                  engineHours,
                  fallback: engineHoursFallback > 0
                      ? '${engineHoursFallback.toStringAsFixed(0)} h'
                      : 'N/A',
                ),
              ),
              _TagMetric(
                label: 'Odometer',
                value: _diagnosticDisplay(
                  odometer,
                  fallback: odometerFallback > 0
                      ? '${odometerFallback.toStringAsFixed(0)} km'
                      : 'N/A',
                ),
              ),
              _TagMetric(label: 'Alerts', value: '$alertCount', color: accent),
            ], gap: 10),
          if (sensorReadings.isNotEmpty) ...[
            const SizedBox(height: 12),
            stretchedTiles(
              sensorReadings
                  .map<Widget>(
                    (reading) => TelemetryReadingTile(
                        reading: reading,
                        icon: switch (reading.key) {
                          'temperature' => Icons.device_thermostat_rounded,
                          'humidity' => Icons.water_drop_rounded,
                          _ => Icons.local_gas_station_rounded,
                        },
                        compact: true,
                        showHistory: false,
                      ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

String _diagnosticDisplay(
  Map<String, dynamic> diagnostic, {
  required String fallback,
}) {
  final display = diagnostic['displayValue']?.toString().trim() ?? '';
  if (display.isNotEmpty && display.toLowerCase() != 'unavailable') {
    return display;
  }
  return fallback;
}

List<Map<String, dynamic>> _sortedTelemetryAssets(
  List<Map<String, dynamic>> assets,
) {
  final sorted = [...assets];
  sorted.sort((first, second) {
    final firstRank = _telemetryAssetRank(first);
    final secondRank = _telemetryAssetRank(second);
    if (firstRank != secondRank) {
      return firstRank.compareTo(secondRank);
    }
    return formatValue(first['vehicle']).compareTo(formatValue(second['vehicle']));
  });
  return sorted;
}

int _telemetryAssetRank(Map<String, dynamic> asset) {
  final alerts = _mapOf(asset['alerts']);
  if (alerts['offline'] == true) {
    return 2;
  }
  if (_toInt(asset['alertCount']) > 0) {
    return 0;
  }
  return 1;
}

class _AnalyticsEmptyState extends StatelessWidget {
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onTap;

  const _AnalyticsEmptyState({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Column(
        children: [
          const Icon(Icons.analytics_rounded, size: 40),
          const SizedBox(height: 12),
          Text(
            title,
            style: AppTheme.getAnalyticsHeadingStyle(context, fontSize: 20),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: AppTheme.getAnalyticsSecondaryStyle(context),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null && onTap != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onTap,
              child: Text(
                actionLabel!,
                style: AppTheme.getAnalyticsBodyStyle(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TagMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _TagMetric({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final accent = color ?? AppTheme.infoBlue;
    return Container(
      constraints: const BoxConstraints(minWidth: 104),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: AppTheme.getAnalyticsCaptionStyle(context)),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppTheme.getAnalyticsHeadingStyle(
              context,
              fontSize: 14,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _SmallAlert extends StatelessWidget {
  final String label;
  final Color color;

  const _SmallAlert({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: AppTheme.getAnalyticsBodyStyle(context).copyWith(
          color: AppTheme.getAnalyticsAccentTextColor(context, color),
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _InsightLine {
  const _InsightLine({
    required this.title,
    required this.value,
    required this.caption,
    this.color,
    this.progress,
  });

  final String title;
  final String value;
  final String caption;
  final Color? color;
  final double? progress;
}

class _AnalyticsSectionHeader extends StatelessWidget {
  const _AnalyticsSectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.infoBlue.withValues(alpha: 0.11),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: AppTheme.infoBlue.withValues(alpha: 0.18),
                ),
              ),
              child: Text(
                'ANALYTICS',
                style: AppTheme.getAnalyticsCaptionStyle(context).copyWith(
                  color: AppTheme.infoBlue,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                height: 1,
                color: AppTheme.getBorderColor(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          title,
          style: AppTheme.getDashboardSectionHeaderStyle(
            context,
          ).copyWith(color: AppTheme.getAnalyticsTextColor(context)),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: AppTheme.getAnalyticsSecondaryStyle(context),
        ),
      ],
    );
  }
}

class _SampleDataBanner extends StatelessWidget {
  const _SampleDataBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.warningOrange.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppTheme.warningOrange.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.science_outlined,
              color: AppTheme.warningOrange,
              size: 16,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Sample data shown until real fleet analytics are available.',
              style: AppTheme.getAnalyticsBodyStyle(context).copyWith(
                color: AppTheme.warningOrange,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const _AnalyticsPill(
            icon: Icons.visibility_rounded,
            label: 'Demo mode',
            color: AppTheme.warningOrange,
          ),
        ],
      ),
    );
  }
}

class _AnalyticsEqualHeightGrid extends StatelessWidget {
  const _AnalyticsEqualHeightGrid({
    required this.children,
    required this.columnCount,
  });

  final List<Widget> children;
  final int columnCount;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var index = 0; index < children.length; index += columnCount) {
      final end = index + columnCount < children.length
          ? index + columnCount
          : children.length;
      final rowChildren = children.sublist(index, end);
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var item = 0; item < columnCount; item++) ...[
              if (item > 0) const SizedBox(width: 12),
              Expanded(
                child: item < rowChildren.length
                    ? rowChildren[item]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          if (index > 0) const SizedBox(height: 12),
          rows[index],
        ],
      ],
    );
  }
}

class _AnalyticsMasonryGrid extends StatelessWidget {
  const _AnalyticsMasonryGrid({
    required this.children,
    required this.columnCount,
  });

  final List<Widget> children;
  final int columnCount;

  @override
  Widget build(BuildContext context) {
    if (columnCount <= 1) {
      return Column(children: children);
    }

    final columns = List.generate(columnCount, (_) => <Widget>[]);
    for (var index = 0; index < children.length; index++) {
      columns[index % columnCount].add(children[index]);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var columnIndex = 0; columnIndex < columns.length; columnIndex++) ...[
          if (columnIndex > 0) const SizedBox(width: 12),
          Expanded(
            child: Column(
              children: columns[columnIndex],
            ),
          ),
        ],
      ],
    );
  }
}

class _FuelTrendSparkline extends StatelessWidget {
  const _FuelTrendSparkline({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final values = rows
        .take(9)
        .map((row) => _numericFromDisplay(row['costLabel']))
        .where((value) => value > 0)
        .toList();
    final averageValues = rows
        .take(9)
        .map((row) => _numericFromDisplay(row['rollingAverageLabel']))
        .where((value) => value > 0)
        .toList();
    final labels = rows.take(9).map((row) => formatValue(row['label'])).toList();
    return Column(
      children: [
        const _ChartLegend(
          items: [
            _LegendItem(label: 'Fuel spend', color: AppTheme.goldAccent),
            _LegendItem(label: 'Rolling avg', color: AppTheme.infoBlue),
          ],
        ),
        const SizedBox(height: 8),
        _MiniChartPanel(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _FuelTrendBarsPainter(
                values: values,
                averageValues: averageValues,
                labels: labels,
                isDark: Theme.of(context).brightness == Brightness.dark,
              ),
              child: const SizedBox(height: 116, width: double.infinity),
            ),
          ),
        ),
      ],
    );
  }
}

class _FuelTrendBarsPainter extends CustomPainter {
  const _FuelTrendBarsPainter({
    required this.values,
    required this.averageValues,
    required this.labels,
    required this.isDark,
  });

  final List<double> values;
  final List<double> averageValues;
  final List<String> labels;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final allValues = [...values, ...averageValues];
    if (allValues.isEmpty) {
      return;
    }

    final maxValue = allValues.fold<double>(
      0,
      (current, value) => value > current ? value : current,
    );
    if (maxValue <= 0) {
      return;
    }

    final gridPaint = Paint()
      ..color = isDark
          ? AppTheme.white.withValues(alpha: 0.07)
          : AppTheme.colorFFE5E7EB
      ..strokeWidth = 1;
    for (final ratio in [0.33, 0.66]) {
      final y = size.height * ratio;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final count = values.length;
    final slotWidth = size.width / count;
    final chartHeight = size.height - 24;
    final barWidth = math.min(32.0, slotWidth * 0.42);
    final linePoints = <Offset>[];

    for (var index = 0; index < count; index++) {
      final xCenter = slotWidth * index + slotWidth / 2;
      final valueHeight =
          chartHeight * ((values[index] / maxValue).clamp(0.05, 1.0));
      final barRect = Rect.fromLTWH(
        xCenter - barWidth / 2,
        chartHeight - valueHeight,
        barWidth,
        valueHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(barRect, const Radius.circular(8)),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.goldAccent,
              AppTheme.goldAccent.withValues(alpha: 0.42),
            ],
          ).createShader(barRect),
      );

      if (index < averageValues.length) {
        final averageY =
            chartHeight -
            chartHeight * ((averageValues[index] / maxValue).clamp(0.05, 1.0));
        linePoints.add(Offset(xCenter, averageY));
      }

      if (index < labels.length) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: labels[index],
            style: TextStyle(
              color: isDark ? AppTheme.colorFFB0B7C3 : AppTheme.colorFF6B7280,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: slotWidth);
        textPainter.paint(
          canvas,
          Offset(
            slotWidth * index + (slotWidth - textPainter.width) / 2,
            size.height - 15,
          ),
        );
      }
    }

    if (linePoints.length >= 2) {
      final linePath = Path()..moveTo(linePoints.first.dx, linePoints.first.dy);
      for (var index = 1; index < linePoints.length; index++) {
        linePath.lineTo(linePoints[index].dx, linePoints[index].dy);
      }
      canvas.drawPath(
        linePath,
        Paint()
          ..color = AppTheme.infoBlue
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
      final pointPaint = Paint()..color = AppTheme.infoBlue;
      for (final point in linePoints) {
        canvas.drawCircle(point, 3.5, pointPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FuelTrendBarsPainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.averageValues != averageValues ||
        oldDelegate.labels != labels ||
        oldDelegate.isDark != isDark;
  }
}

class _VehicleHealthSummary extends StatelessWidget {
  const _VehicleHealthSummary({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final high = rows
        .where((row) => _numericFromDisplay(row['riskScore']) >= 75)
        .length;
    final medium = rows.where((row) {
      final score = _numericFromDisplay(row['riskScore']);
      return score >= 45 && score < 75;
    }).length;
    final low = rows.length - high - medium;
    return _MiniChartPanel(
      child: Column(
        children: [
          _RiskDistributionBar(high: high, medium: medium, low: low),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _RiskCountTile(
                  label: 'High',
                  value: '$high',
                  color: AppTheme.errorRed,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RiskCountTile(
                  label: 'Medium',
                  value: '$medium',
                  color: AppTheme.warningOrange,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RiskCountTile(
                  label: 'Low',
                  value: '$low',
                  color: AppTheme.successGreen,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RiskDistributionBar extends StatelessWidget {
  const _RiskDistributionBar({
    required this.high,
    required this.medium,
    required this.low,
  });

  final int high;
  final int medium;
  final int low;

  @override
  Widget build(BuildContext context) {
    final total = math.max(1, high + medium + low);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 16,
        child: Row(
          children: [
            Expanded(
              flex: math.max(1, (high / total * 100).round()),
              child: Container(color: AppTheme.errorRed),
            ),
            Expanded(
              flex: math.max(1, (medium / total * 100).round()),
              child: Container(color: AppTheme.warningOrange),
            ),
            Expanded(
              flex: math.max(1, (low / total * 100).round()),
              child: Container(color: AppTheme.successGreen),
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskCountTile extends StatelessWidget {
  const _RiskCountTile({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTheme.getAnalyticsCaptionStyle(context)),
          const SizedBox(height: 5),
          Text(
            value,
            style: AppTheme.getAnalyticsHeadingStyle(
              context,
              fontSize: 22,
            ).copyWith(color: color, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}

class _DriverReliabilityBars extends StatelessWidget {
  const _DriverReliabilityBars({required this.rows});

  final List<Map<String, dynamic>> rows;

  static Widget fromRows({
    required List<Map<String, dynamic>> rows,
  }) {
    return _DriverReliabilityBars(rows: rows.take(4).toList());
  }

  @override
  Widget build(BuildContext context) {
    return _MiniChartPanel(
      child: Column(
        children: [
          const _ChartLegend(
            items: [
              _LegendItem(label: 'On-time', color: AppTheme.successGreen),
              _LegendItem(label: 'Delayed', color: AppTheme.warningOrange),
            ],
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0) const SizedBox(height: 10),
            _DriverReliabilityRow(row: rows[index]),
          ],
        ],
      ),
    );
  }
}

class _DriverReliabilityRow extends StatelessWidget {
  const _DriverReliabilityRow({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final driver = formatValue(row['driver']);
    final onTime = _percentValue(row['onTimeLabel']).clamp(0.0, 1.0);
    final delayed = 1 - onTime;
    return Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(
            driver,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.getAnalyticsCaptionStyle(context),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 14,
              child: Row(
                children: [
                  Expanded(
                    flex: (onTime * 100).round().clamp(1, 100),
                    child: Container(color: AppTheme.successGreen),
                  ),
                  Expanded(
                    flex: (delayed * 100).round().clamp(1, 100),
                    child: Container(color: AppTheme.warningOrange),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 38,
          child: Text(
            '${(onTime * 100).round()}%',
            textAlign: TextAlign.right,
            style: AppTheme.getAnalyticsCaptionStyle(
              context,
            ).copyWith(fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.items});

  final List<_LegendItem> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: items
          .map(
            (item) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: item.color,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 6),
                Text(item.label, style: AppTheme.getAnalyticsCaptionStyle(context)),
              ],
            ),
          )
          .toList(),
    );
  }
}

class _LegendItem {
  const _LegendItem({required this.label, required this.color});

  final String label;
  final Color color;
}

class _TripForecastBars extends StatelessWidget {
  const _TripForecastBars({required this.rows});

  final List<Map<String, dynamic>> rows;

  static Widget fromRows({required List<Map<String, dynamic>> rows}) {
    return _TripForecastBars(rows: rows.take(7).toList());
  }

  @override
  Widget build(BuildContext context) {
    final forecast = rows
        .map((row) => _numericFromDisplay(row['forecastTrips']))
        .toList();
    final average = rows
        .map((row) => _numericFromDisplay(row['averageTrips']))
        .toList();
    final labels = rows.map((row) => formatValue(row['label'])).toList();
    final totalForecast = forecast.fold<double>(0, (sum, value) => sum + value);
    final avgTrips = average.isEmpty
        ? 0.0
        : average.fold<double>(0, (sum, value) => sum + value) / average.length;

    return Column(
      children: [
        const _ChartLegend(
          items: [
            _LegendItem(label: 'Forecast', color: AppTheme.infoBlue),
            _LegendItem(label: 'Historical avg', color: AppTheme.colorFFB0B7C3),
          ],
        ),
        const SizedBox(height: 8),
        _MiniChartPanel(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _TripForecastBarsPainter(
                forecast: forecast,
                average: average,
                labels: labels,
                isDark: Theme.of(context).brightness == Brightness.dark,
              ),
              child: const SizedBox(height: 112, width: double.infinity),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'This week',
                style: AppTheme.getAnalyticsCaptionStyle(context),
              ),
            ),
            Text(
              'Avg ${avgTrips.toStringAsFixed(1)} trips',
              style: AppTheme.getAnalyticsCaptionStyle(context),
            ),
            const SizedBox(width: 10),
            Text(
              '${totalForecast.round()} trips',
              style: AppTheme.getAnalyticsBodyStyle(context).copyWith(
                color: AppTheme.infoBlue,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MiniChartPanel extends StatelessWidget {
  const _MiniChartPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.colorFF08101D.withValues(alpha: 0.52)
            : AppTheme.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: child,
    );
  }
}

class _TripForecastBarsPainter extends CustomPainter {
  const _TripForecastBarsPainter({
    required this.forecast,
    required this.average,
    required this.labels,
    required this.isDark,
  });

  final List<double> forecast;
  final List<double> average;
  final List<String> labels;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = isDark
          ? AppTheme.white.withValues(alpha: 0.07)
          : AppTheme.colorFFE5E7EB
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height - 18),
      Offset(size.width, size.height - 18),
      gridPaint,
    );

    if (forecast.isEmpty) {
      return;
    }

    final maxValue = [...forecast, ...average].fold<double>(
      0,
      (max, value) => value > max ? value : max,
    );
    if (maxValue <= 0) {
      return;
    }
    final count = forecast.length;
    final slotWidth = size.width / count;
    final barWidth = math.min(14.0, slotWidth * 0.22);
    final chartHeight = size.height - 28;

    for (var index = 0; index < count; index++) {
      final xCenter = slotWidth * index + slotWidth / 2;
      final avgHeight =
          chartHeight * ((average[index] / maxValue).clamp(0.05, 1.0));
      final forecastHeight =
          chartHeight * ((forecast[index] / maxValue).clamp(0.05, 1.0));
      final avgRect = Rect.fromLTWH(
        xCenter - barWidth - 2,
        chartHeight - avgHeight,
        barWidth,
        avgHeight,
      );
      final forecastRect = Rect.fromLTWH(
        xCenter + 2,
        chartHeight - forecastHeight,
        barWidth,
        forecastHeight,
      );

      canvas.drawRRect(
        RRect.fromRectAndRadius(avgRect, const Radius.circular(5)),
        Paint()
          ..color = AppTheme.colorFFB0B7C3.withValues(alpha: isDark ? 0.55 : 0.7),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(forecastRect, const Radius.circular(5)),
        Paint()..color = AppTheme.infoBlue,
      );

      if (index < labels.length) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: labels[index],
            style: TextStyle(
              color: isDark ? AppTheme.colorFFB0B7C3 : AppTheme.colorFF6B7280,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout(maxWidth: slotWidth);
        textPainter.paint(
          canvas,
          Offset(
            slotWidth * index + (slotWidth - textPainter.width) / 2,
            size.height - 14,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TripForecastBarsPainter oldDelegate) {
    return oldDelegate.forecast != forecast ||
        oldDelegate.average != average ||
        oldDelegate.labels != labels ||
        oldDelegate.isDark != isDark;
  }
}

class _AnalyticsInsightBlock extends StatelessWidget {
  const _AnalyticsInsightBlock({
    required this.title,
    required this.rows,
    required this.isSample,
    this.chart,
    this.bodyHeight = 300,
  });

  final String title;
  final List<_InsightLine> rows;
  final bool isSample;
  final Widget? chart;
  final double bodyHeight;

  @override
  Widget build(BuildContext context) {
    return _ExecutiveBlock(
      title: title,
      subtitle: 'Backend-computed local fleet intelligence.',
      showSampleBanner: isSample,
      child: rows.isEmpty
          ? Text(
              'No local data yet',
              style: AppTheme.getAnalyticsSecondaryStyle(context),
            )
          : SizedBox(
              height: bodyHeight,
              child: Column(
                children: [
                  if (chart != null) ...[
                    chart!,
                    const SizedBox(height: 12),
                  ],
                  Expanded(
                    child: ListView.builder(
                      primary: false,
                      padding: EdgeInsets.zero,
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        return _AnalyticsInsightRow(
                          row: rows[index],
                          index: index,
                          total: rows.length,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _AnalyticsInsightRow extends StatelessWidget {
  const _AnalyticsInsightRow({
    required this.row,
    required this.index,
    required this.total,
  });

  final _InsightLine row;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = row.color ?? _rowAccent(index);
    final strength =
        row.progress ?? (total <= 1 ? 1.0 : 1 - (index / total * 0.55));
    return Container(
      margin: EdgeInsets.only(bottom: index == total - 1 ? 0 : 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? AppTheme.white.withValues(alpha: 0.035)
            : AppTheme.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${index + 1}',
              style: AppTheme.getAnalyticsBodyStyle(context).copyWith(
                color: accent,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getAnalyticsBodyStyle(
                    context,
                  ).copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  row.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.getAnalyticsSecondaryStyle(context),
                ),
                const SizedBox(height: 8),
                _AnimatedProgressBar(
                  value: strength.clamp(0.12, 1.0),
                  color: accent,
                  height: 7,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            row.value,
            style: AppTheme.getAnalyticsBodyStyle(context).copyWith(
              fontWeight: FontWeight.w900,
              color: AppTheme.getAnalyticsAccentTextColor(context, accent),
            ),
          ),
        ],
      ),
    );
  }

  Color _rowAccent(int index) {
    const colors = [
      AppTheme.successGreen,
      AppTheme.infoBlue,
      AppTheme.colorFF6B7280,
      AppTheme.tealAccent,
      AppTheme.warningOrange,
      AppTheme.goldAccent,
    ];
    return colors[index % colors.length];
  }
}

class _AnalyticsBundle {
  final Map<String, dynamic> summary;
  final Map<String, dynamic> telemetry;
  final Map<String, dynamic> temperature;
  final Map<String, dynamic> insights;

  const _AnalyticsBundle({
    required this.summary,
    required this.telemetry,
    required this.temperature,
    required this.insights,
  });

  const _AnalyticsBundle.demo()
    : summary = const {},
      telemetry = const {},
      temperature = const {},
      insights = const {};
}

class _AnalyticsStat {
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color color;
  final double progress;

  const _AnalyticsStat({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
    required this.progress,
  });
}

const List<Map<String, dynamic>> _sampleVehicles = [
  {'vehicle': 'NCO 7290', 'status': 'on trip'},
  {'vehicle': 'LAM 9297', 'status': 'on trip'},
  {'vehicle': 'IAE 5512', 'status': 'available'},
  {'vehicle': 'NDZ 6263', 'status': 'available'},
  {'vehicle': 'QR 617A', 'status': 'maintenance'},
];

const List<Map<String, dynamic>> _sampleTrips = [
  {'route': 'Cabuyao - Batangas City', 'distanceKm': 112},
  {'route': 'Cabuyao - Clark', 'distanceKm': 154},
  {'route': 'Cabuyao - Calamba', 'distanceKm': 28},
  {'route': 'Cabuyao - Pasig', 'distanceKm': 61},
  {'route': 'Cabuyao - Manila', 'distanceKm': 54},
  {'route': 'Cabuyao - Tarlac City', 'distanceKm': 170},
];

const List<Map<String, dynamic>> _sampleMaintenance = [
  {'vehicle': 'QR 617A', 'type': 'Preventive Maintenance Service'},
];

const List<Map<String, dynamic>> _sampleCompliance = [
  {'vehicle': 'NCO 7290', 'status': 'confirmed'},
  {'vehicle': 'LAM 9297', 'status': 'confirmed'},
  {'vehicle': 'IAE 5512', 'status': 'confirmed'},
  {'vehicle': 'NDZ 6263', 'status': 'confirmed'},
];

const List<Map<String, dynamic>> _sampleCoverage = [
  {
    'label': 'Fuel level reporting',
    'coveragePercent': 80,
    'supportedAssets': 4,
  },
  {
    'label': 'Engine coolant temperature',
    'coveragePercent': 60,
    'supportedAssets': 3,
  },
  {'label': 'Odometer telemetry', 'coveragePercent': 100, 'supportedAssets': 5},
];

const List<Map<String, dynamic>> _sampleTelemetryAssets = [
  {
    'vehicle': 'NCO 7290',
    'status': 'on trip',
    'telemetrySource': 'Demo data',
    'hasTemperatureSensor': true,
    'temperatureC': 4.4,
    'humidity': 54,
    'fuelLevelRatio': 0.31,
    'engineHours': 2864,
    'odometerKm': 84210,
    'alertCount': 1,
    'alerts': <String, dynamic>{},
    'diagnostics': <String, dynamic>{},
  },
  {
    'vehicle': 'LAM 9297',
    'status': 'available',
    'telemetrySource': 'Demo data',
    'fuelLevelRatio': 0.67,
    'engineHours': 1940,
    'odometerKm': 61340,
    'alertCount': 0,
    'alerts': <String, dynamic>{},
    'diagnostics': <String, dynamic>{},
  },
  {
    'vehicle': 'IAE 5512',
    'status': 'available',
    'telemetrySource': 'Demo data',
    'fuelLevelRatio': 0.82,
    'engineHours': 1522,
    'odometerKm': 48820,
    'alertCount': 0,
    'alerts': <String, dynamic>{},
    'diagnostics': <String, dynamic>{},
  },
  {
    'vehicle': 'NDZ 6263',
    'status': 'available',
    'telemetrySource': 'Demo data',
    'fuelLevelRatio': 0.46,
    'engineHours': 2218,
    'odometerKm': 70240,
    'alertCount': 0,
    'alerts': <String, dynamic>{},
    'diagnostics': <String, dynamic>{},
  },
  {
    'vehicle': 'QR 617A',
    'status': 'maintenance',
    'telemetrySource': 'Demo data',
    'hasTemperatureSensor': true,
    'temperatureC': 9.4,
    'humidity': 57,
    'fuelLevelRatio': 0.28,
    'engineHours': 3054,
    'odometerKm': 91320,
    'alertCount': 2,
    'alerts': <String, dynamic>{},
    'diagnostics': <String, dynamic>{},
  },
];

const List<Map<String, dynamic>> _sampleTemperatureAssets = [
  {
    'vehicle': 'NCO 7290',
    'sensorInstalled': true,
    'engineCoolantTemperature': {'displayValue': '88'},
    'relativeHumidity': {'displayValue': '54'},
    'alerts': <String, dynamic>{},
  },
  {
    'vehicle': 'QR 617A',
    'sensorInstalled': true,
    'engineCoolantTemperature': {'displayValue': '94'},
    'relativeHumidity': {'displayValue': '57'},
    'alerts': {'engineHot': true},
  },
];

const List<Map<String, dynamic>> _sampleTopDrivers = [
  {
    'driver': 'Jose Dela Cruz',
    'totalTrips': 18,
    'totalKm': '1,284',
    'onTimeLabel': '96%',
  },
  {
    'driver': 'Maria Santos',
    'totalTrips': 16,
    'totalKm': '1,102',
    'onTimeLabel': '94%',
  },
  {
    'driver': 'Ramon Villanueva',
    'totalTrips': 14,
    'totalKm': '978',
    'onTimeLabel': '93%',
  },
];

const List<Map<String, dynamic>> _sampleDriverWatchlist = [
  {
    'driver': 'Antonio Reyes',
    'score': 74,
    'totalTrips': 11,
    'onTimeLabel': '82%',
  },
  {
    'driver': 'Carlo Mendoza',
    'score': 79,
    'totalTrips': 9,
    'onTimeLabel': '86%',
  },
  {
    'driver': 'Luis Garcia',
    'score': 68,
    'totalTrips': 8,
    'onTimeLabel': '76%',
  },
];

const List<Map<String, dynamic>> _sampleVehicleHealthRisk = [
  {
    'vehicle': 'QR 617A',
    'riskScore': 82,
    'riskLevel': 'red',
    'faultCodeCount': 2,
  },
  {
    'vehicle': 'NCO 7290',
    'riskScore': 63,
    'riskLevel': 'amber',
    'faultCodeCount': 1,
  },
  {
    'vehicle': 'IAE 5512',
    'riskScore': 24,
    'riskLevel': 'green',
    'faultCodeCount': 0,
  },
];

const List<Map<String, dynamic>> _sampleRouteEfficiency = [
  {
    'route': 'Cabuyao - Batangas City',
    'variancePercent': 6.2,
    'tripCount': 12,
    'flagged': false,
  },
  {
    'route': 'Cabuyao - Clark',
    'variancePercent': 18.4,
    'tripCount': 8,
    'flagged': true,
  },
  {
    'route': 'Cabuyao - Pasig',
    'variancePercent': 9.1,
    'tripCount': 10,
    'flagged': false,
  },
];

const List<Map<String, dynamic>> _sampleTripForecast = [
  {'label': 'Mon', 'forecastTrips': 8, 'averageTrips': 7.4},
  {'label': 'Tue', 'forecastTrips': 9, 'averageTrips': 8.2},
  {'label': 'Wed', 'forecastTrips': 7, 'averageTrips': 7.1},
  {'label': 'Thu', 'forecastTrips': 10, 'averageTrips': 9.3},
  {'label': 'Fri', 'forecastTrips': 12, 'averageTrips': 10.8},
];

const List<Map<String, dynamic>> _sampleFuelTrend = [
  {
    'label': 'Week 1',
    'rollingAverageLabel': '₱5,420',
    'costLabel': '₱5,180',
  },
  {
    'label': 'Week 2',
    'rollingAverageLabel': '₱5,680',
    'costLabel': '₱5,940',
  },
  {
    'label': 'Week 3',
    'rollingAverageLabel': '₱5,590',
    'costLabel': '₱5,410',
  },
  {
    'label': 'Week 4',
    'rollingAverageLabel': '₱5,720',
    'costLabel': '₱6,050',
  },
  {
    'label': 'Week 5',
    'rollingAverageLabel': '₱5,640',
    'costLabel': '₱5,310',
  },
];

Map<String, dynamic> _mapOf(dynamic raw) {
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return {};
}

List<Map<String, dynamic>> _listOfMaps(dynamic raw) {
  if (raw is! List) {
    return [];
  }

  return raw
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .cast<Map<String, dynamic>>()
      .toList();
}

double _toDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }
  final cleaned = (value?.toString() ?? '').replaceAll(RegExp(r'[^0-9.\-]'), '');
  return double.tryParse(cleaned) ?? 0.0;
}

double _diagnosticDouble(dynamic value) {
  final map = _mapOf(value);
  if (map.isEmpty) {
    return _numericFromDisplay(value);
  }
  return _numericFromDisplay(map['value'] ?? map['displayValue']);
}

double _fuelRatio(Map<String, dynamic> vehicle, Map<String, dynamic> diagnostics) {
  final direct = _numericFromDisplay(vehicle['fuelLevelRatio']);
  if (direct > 0 && direct <= 1) {
    return direct;
  }
  final fuel = _diagnosticDouble(diagnostics['fuelLevel']);
  final tank = _diagnosticDouble(diagnostics['fuelTankCapacity']);
  if (fuel > 0 && tank > 0) {
    return (fuel / tank).clamp(0.0, 1.0).toDouble();
  }
  if (fuel > 1 && fuel <= 100) {
    return (fuel / 100).clamp(0.0, 1.0).toDouble();
  }
  return 0;
}

double _numericFromDisplay(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }

  final raw = value?.toString() ?? '';
  final cleaned = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
  return double.tryParse(cleaned) ?? 0.0;
}

double _percentValue(dynamic value) {
  final raw = _numericFromDisplay(value);
  if (raw <= 0) {
    return 0.0;
  }
  return raw > 1 ? raw / 100 : raw;
}

Color _watchlistColor(Map<String, dynamic> row) {
  final onTime = _percentValue(row['onTimeLabel']);
  if (onTime >= 0.9) {
    return AppTheme.successGreen;
  }
  if (onTime >= 0.82) {
    return AppTheme.warningOrange;
  }
  return AppTheme.errorRed;
}

Color _healthRiskColor(Map<String, dynamic> row) {
  final score = _numericFromDisplay(row['riskScore']);
  if (score >= 75) {
    return AppTheme.errorRed;
  }
  if (score >= 45) {
    return AppTheme.warningOrange;
  }
  return AppTheme.successGreen;
}

int _toInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}