import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../config/pioneer_runtime_config.dart';
import '../services/backend_api.dart';
import '../services/drivers_store.dart';
import '../services/fleet_sync_service.dart';
import '../services/page_cache_service.dart';
import '../theme/app_theme.dart';
import '../utils/display_format.dart';
import '../widgets/dashboard_layout.dart';
import '../widgets/page_skeletons.dart';

class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> {
  static const String _cacheKey = 'analytics_page';

  late Future<_AnalyticsBundle> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(forceRefresh: true);
  }

  Future<_AnalyticsBundle> _load({bool forceRefresh = false}) async {
    return PageCacheService.getOrLoad<_AnalyticsBundle>(
      key: _cacheKey,
      ttl: PageCacheService.analyticsTtl,
      forceRefresh: forceRefresh,
      loader: () => BackendApiService.loadWithWarmRetry<_AnalyticsBundle>(
        attempts: forceRefresh ? 2 : 4,
        request: (retryForceRefresh) async {
          final effectiveForceRefresh = forceRefresh || retryForceRefresh;
          refreshFleetBootstrapSilently(forceRefresh: effectiveForceRefresh);
          warmOperationalCachesSilently(forceRefresh: effectiveForceRefresh);
          final analytics = await BackendApiService.getFleetSummaryAnalytics(
            forceRefresh: effectiveForceRefresh,
          );

          return _AnalyticsBundle(
            summary: _mapOf(analytics['operations']),
            telemetry: _mapOf(analytics['telemetry']),
            temperature: _mapOf(analytics['temperature']),
            insights: analytics,
          );
        },
      ),
    );
  }

  void _reload() {
    setState(() {
      _future = _load(forceRefresh: true);
    });
  }

  _AnalyticsBundle? _cachedBundle() {
    final cached = PageCacheService.anyData<_AnalyticsBundle>(_cacheKey);
    if (cached != null) {
      return cached;
    }

    final analytics = BackendApiService.peekCachedDataMap(
      '/fleet/summary/analytics',
    );
    if (analytics == null || analytics.isEmpty) {
      return null;
    }

    return _AnalyticsBundle(
      summary: _mapOf(analytics['operations']),
      telemetry: _mapOf(analytics['telemetry']),
      temperature: _mapOf(analytics['temperature']),
      insights: analytics,
    );
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
        initialData: _cachedBundle(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const PioneerRouteSkeletonBody(routeName: '/analytics');
          }

          if (snapshot.hasError || !snapshot.hasData) {
            return _AnalyticsShell(
              child: _AnalyticsEmptyState(
                title: 'Analytics could not be loaded',
                message:
                    'The page is now wired to live summary, telemetry, and temperature endpoints. Retry once the backend is reachable.',
                actionLabel: 'Retry',
                onTap: _reload,
              ),
            );
          }

          final bundle = snapshot.data!;
          final sourceVehicles = _listOfMaps(bundle.summary['vehicles']);
          final sourceTrips = _listOfMaps(bundle.summary['trips']);
          final sourceMaintenance = _listOfMaps(bundle.summary['maintenance']);
          final sourceCompliance = _listOfMaps(bundle.summary['compliance']);
          final usingSampleOperations =
              PioneerRuntimeConfig.showMockData &&
              sourceVehicles.isEmpty &&
              sourceTrips.isEmpty &&
              sourceMaintenance.isEmpty &&
              sourceCompliance.isEmpty;
          final vehicles = usingSampleOperations
              ? _sampleVehicles
              : sourceVehicles;
          final trips = usingSampleOperations ? _sampleTrips : sourceTrips;
          final maintenance = usingSampleOperations
              ? _sampleMaintenance
              : sourceMaintenance;
          final compliance = usingSampleOperations
              ? _sampleCompliance
              : sourceCompliance;
          final sourceTelemetryAssets = _listOfMaps(bundle.telemetry['assets']);
          final sourceCoverageRows = _listOfMaps(bundle.telemetry['coverage']);
          final sourceTemperatureAssets = _listOfMaps(
            bundle.temperature['assets'],
          );
          final driverPerformance =
              _listOfMaps(bundle.insights['driverPerformanceTop']).isNotEmpty
              ? _listOfMaps(bundle.insights['driverPerformanceTop'])
              : _listOfMaps(bundle.insights['driverPerformance']);
          final bottomDriverPerformance = _listOfMaps(
            bundle.insights['driverPerformanceBottom'],
          );
          final vehicleHealthRisk = _listOfMaps(
            bundle.insights['vehicleHealthRisk'],
          );
          final routeEfficiency = _listOfMaps(
            bundle.insights['routeEfficiency'],
          );
          final tripForecast = _listOfMaps(
            bundle.insights['tripVolumeForecast'],
          );
          final sourceFuelTrend = _listOfMaps(
            _mapOf(bundle.insights['fuelTrend'])['sparkline'],
          );
          final resolvedDriverPerformance = driverPerformance
              .map(_withResolvedDriverName)
              .toList();
          final resolvedBottomDriverPerformance = bottomDriverPerformance
              .map(_withResolvedDriverName)
              .toList();
          final totalAssets = vehicles.length;
          final activeAssets = vehicles
              .where((vehicle) => vehicle['status']?.toString() == 'on trip')
              .length;
          final utilization = totalAssets == 0
              ? 0.0
              : activeAssets / totalAssets;
          final sourceColdChainAlerts = _toInt(
            _mapOf(bundle.telemetry)['coldChainVarianceAssets'],
          );
          final sourceLowFuelAlerts = _toInt(
            _mapOf(bundle.telemetry)['lowFuelAssets'],
          );
          final sourceEngineHotAlerts = _toInt(
            _mapOf(bundle.telemetry)['engineHotAssets'],
          );
          final usingSampleTelemetry =
              PioneerRuntimeConfig.showMockData &&
              sourceTelemetryAssets.isEmpty &&
              sourceCoverageRows.isEmpty &&
              sourceColdChainAlerts == 0 &&
              sourceLowFuelAlerts == 0 &&
              sourceEngineHotAlerts == 0;
          final telemetryAssets = usingSampleTelemetry
              ? _sampleTelemetryAssets
              : sourceTelemetryAssets;
          final coverageRows = usingSampleTelemetry
              ? _sampleCoverage
              : sourceCoverageRows;
          final lowFuelAlerts = usingSampleTelemetry ? 1 : sourceLowFuelAlerts;
          final engineHotAlerts = usingSampleTelemetry
              ? 1
              : sourceEngineHotAlerts;
          final coldChainAlerts = sourceColdChainAlerts;
          final usingSampleTemperature =
              PioneerRuntimeConfig.showMockData && sourceTemperatureAssets.isEmpty;
          final temperatureAssets = usingSampleTemperature
              ? _sampleTemperatureAssets
              : sourceTemperatureAssets;
          final topDriverRows = resolvedDriverPerformance.isEmpty &&
                  PioneerRuntimeConfig.showMockData
              ? _sampleTopDrivers
              : resolvedDriverPerformance;
          final watchlistDriverRows = resolvedBottomDriverPerformance.isEmpty &&
                  PioneerRuntimeConfig.showMockData
              ? _sampleDriverWatchlist
              : resolvedBottomDriverPerformance;
          final healthRows = vehicleHealthRisk.isEmpty &&
                  PioneerRuntimeConfig.showMockData
              ? _sampleVehicleHealthRisk
              : vehicleHealthRisk;
          final efficiencyRows = routeEfficiency.isEmpty &&
                  PioneerRuntimeConfig.showMockData
              ? _sampleRouteEfficiency
              : routeEfficiency;
          final forecastRows = tripForecast.isEmpty &&
                  PioneerRuntimeConfig.showMockData
              ? _sampleTripForecast
              : tripForecast;
          final fuelTrend = sourceFuelTrend.isEmpty &&
                  PioneerRuntimeConfig.showMockData
              ? _sampleFuelTrend
              : sourceFuelTrend;

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
                        child: Column(
                          children: [
                            _PriorityBar(
                              label: 'Utilization',
                              value: utilization,
                              valueLabel:
                                  '${(utilization * 100).toStringAsFixed(0)}%',
                              color: AppTheme.primaryBlue,
                            ),
                            _PriorityBar(
                              label: 'Maintenance load',
                              value: totalAssets == 0
                                  ? 0
                                  : maintenance.length / totalAssets,
                              valueLabel: '${maintenance.length} assets',
                              color: AppTheme.warningOrange,
                            ),
                            _PriorityBar(
                              label: 'Compliance visibility',
                              value: trips.isEmpty
                                  ? 0
                                  : compliance.length / trips.length,
                              valueLabel: '${compliance.length} logs',
                              color: AppTheme.successGreen,
                            ),
                          ],
                        ),
                      );
                      final alertsBlock = _ExecutiveBlock(
                        title: 'Top telemetry alerts',
                        subtitle:
                            'Fuel, engine temperature, and cold-chain conditions that need operations attention.',
                        showSampleBanner: usingSampleTelemetry,
                        child: _buildTelemetryAlerts(
                          context,
                          lowFuelAlerts: lowFuelAlerts,
                          engineHotAlerts: engineHotAlerts,
                          coldChainAlerts: coldChainAlerts,
                        ),
                      );
                      final coverageBlock = coverageRows.isEmpty
                          ? null
                          : _ExecutiveBlock(
                              title: 'Fleet telemetry coverage',
                              subtitle:
                                  'How many assets are actually reporting each premium diagnostic.',
                              showSampleBanner: usingSampleTelemetry,
                              child: Column(
                                children: coverageRows
                                    .take(6)
                                    .map(
                                      (item) => _CoverageRow(
                                        label:
                                            item['label']?.toString() ??
                                            'Diagnostic',
                                        coverage:
                                            _toDouble(item['coveragePercent']) /
                                            100,
                                        supportedAssets: _toInt(
                                          item['supportedAssets'],
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            );
                      final temperatureBlock = temperatureAssets.isEmpty
                          ? null
                          : _ExecutiveBlock(
                              title: 'Temperature watchlist',
                              subtitle:
                                  'Engine and cargo conditions from temperature-aware assets.',
                              showSampleBanner: usingSampleTemperature,
                              child: Column(
                                children: temperatureAssets
                                    .take(6)
                                    .map(
                                      (asset) => _TemperatureRow(asset: asset),
                                    )
                                    .toList(),
                              ),
                            );

                      Widget rowPair(Widget first, Widget? second) {
                        if (stacked || second == null) {
                          return Column(
                            children: [
                              first,
                              if (second != null) ...[
                                const SizedBox(height: 12),
                                second,
                              ],
                            ],
                          );
                        }

                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: first),
                              const SizedBox(width: 12),
                              Expanded(child: second),
                            ],
                          ),
                        );
                      }

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

                      return Column(
                        children: [
                          rowPair(commandBlock, coverageBlock),
                          const SizedBox(height: 12),
                          rowPair(alertsBlock, temperatureBlock),
                        ],
                      );
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
                            isSample:
                                resolvedDriverPerformance.isEmpty &&
                                PioneerRuntimeConfig.showMockData,
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
                            isSample:
                                resolvedBottomDriverPerformance.isEmpty &&
                                PioneerRuntimeConfig.showMockData,
                            rows: watchlistDriverRows
                                .take(5)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['driver']),
                                    value: '${formatValue(row['score'])} score',
                                    caption:
                                        '${formatValue(row['totalTrips'])} trips | ${formatValue(row['onTimeLabel'])} on-time',
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Vehicle Health Risk',
                            isSample:
                                vehicleHealthRisk.isEmpty &&
                                PioneerRuntimeConfig.showMockData,
                            rows: healthRows
                                .take(6)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['vehicle']),
                                    value: '${formatValue(row['riskScore'])}',
                                    caption:
                                        '${formatValue(row['riskLevel'])} risk | ${formatValue(row['faultCodeCount'])} faults',
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Route Efficiency',
                            isSample:
                                routeEfficiency.isEmpty &&
                                PioneerRuntimeConfig.showMockData,
                            rows: efficiencyRows
                                .take(6)
                                .map(
                                  (row) => _InsightLine(
                                    title: formatValue(row['route']),
                                    value:
                                        '${formatValue(row['variancePercent'])}%',
                                    caption:
                                        '${formatValue(row['tripCount'])} trips | ${row['flagged'] == true ? 'Flagged' : 'Normal'}',
                                  ),
                                )
                                .toList(),
                          ),
                          _AnalyticsInsightBlock(
                            title: 'Trip Forecast',
                            isSample:
                                tripForecast.isEmpty &&
                                PioneerRuntimeConfig.showMockData,
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
                            isSample:
                                sourceFuelTrend.isEmpty &&
                                PioneerRuntimeConfig.showMockData,
                            rows: fuelTrend
                                .take(7)
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
                          columnCount: constraints.maxWidth >= 1120
                              ? 3
                              : constraints.maxWidth >= 720
                              ? 2
                              : 1,
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
                      child: Column(
                        children: telemetryAssets
                            .take(8)
                            .map((asset) => _TelemetryAssetRow(asset: asset))
                            .toList(),
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

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        if (lowFuelAlerts > 0)
          _InsightChip(
            title: 'Low fuel',
            value: '$lowFuelAlerts',
            color: AppTheme.warningOrange,
            icon: Icons.local_gas_station_rounded,
          ),
        if (engineHotAlerts > 0)
          _InsightChip(
            title: 'Hot engine',
            value: '$engineHotAlerts',
            color: AppTheme.errorRed,
            icon: Icons.thermostat_rounded,
          ),
        if (coldChainAlerts > 0)
          _InsightChip(
            title: 'Cold-chain variance',
            value: '$coldChainAlerts',
            color: AppTheme.primaryBlue,
            icon: Icons.ac_unit_rounded,
          ),
      ],
    );
  }

  Map<String, dynamic> _withResolvedDriverName(Map<String, dynamic> row) {
    return {
      ...row,
      'driver': _resolveDriverName(
        row['driver'] ?? row['driverName'] ?? row['name'] ?? row['driverId'],
      ),
    };
  }

  String _resolveDriverName(dynamic rawValue) {
    final raw = rawValue?.toString().trim() ?? '';
    final drivers = driversNotifier.value;
    final rawLower = raw.toLowerCase();

    for (final driver in drivers) {
      final name = driver['name']?.toString().trim() ?? '';
      if (name.isEmpty) {
        continue;
      }

      final keys =
          <dynamic>[
                driver['name'],
                driver['driver'],
                driver['driverId'],
                driver['id'],
                driver['geotabId'],
                driver['geotabUserId'],
                driver['email'],
                driver['employeeNumber'],
                driver['assignedVehicleGeotabId'],
              ]
              .map((value) => value?.toString().trim().toLowerCase() ?? '')
              .where((value) => value.isNotEmpty)
              .toSet();

      if (keys.contains(rawLower)) {
        return name;
      }
    }

    if (_looksLikeDriverName(raw)) {
      return raw;
    }

    return 'Unassigned Driver';
  }

  bool _looksLikeDriverName(String value) {
    final trimmed = value.trim();
    final lower = trimmed.toLowerCase();
    if (trimmed.isEmpty ||
        lower == 'n/a' ||
        lower == 'unknown' ||
        lower == 'unknown driver' ||
        lower == 'unavailable') {
      return false;
    }

    if (RegExp(
      r'^[a-z][0-9a-z]{1,5}$',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return false;
    }

    if (RegExp(r'^[0-9a-f]{6,}$', caseSensitive: false).hasMatch(trimmed)) {
      return false;
    }

    return trimmed.contains(' ') || trimmed.length > 6;
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
      ),
      _AnalyticsStat(
        label: 'Trip Throughput',
        value: '$tripCount',
        caption: 'Recent live plus historical trips',
        icon: Icons.route_rounded,
        color: AppTheme.successGreen,
      ),
      _AnalyticsStat(
        label: 'Maintenance Due',
        value: '$maintenanceCount',
        caption: 'Service and connectivity exceptions',
        icon: Icons.build_circle_rounded,
        color: AppTheme.warningOrange,
      ),
      _AnalyticsStat(
        label: 'Compliance Logs',
        value: '$complianceCount',
        caption: 'Latest HOS visibility',
        icon: Icons.verified_user_rounded,
        color: AppTheme.goldAccent,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: Theme.of(context).brightness == Brightness.dark
              ? const [AppTheme.colorFF101827, AppTheme.colorFF14213A]
              : const [AppTheme.white, AppTheme.colorFFF0F6FF],
        ),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getElevatedShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Executive intelligence',
            style: AppTheme.getAnalyticsHeadingStyle(context, fontSize: 30),
          ),
          const SizedBox(height: 8),
          Text(
            'A premium, operations-first view of utilization, cold-chain risk, service readiness, and telematics coverage.',
            style: AppTheme.getAnalyticsSecondaryStyle(context),
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

              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(BuildContext context, _AnalyticsStat stat) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppTheme.white.withValues(alpha: 0.03)
            : AppTheme.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: stat.color.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(stat.icon, color: stat.color, size: 20),
          const SizedBox(height: 12),
          Text(
            stat.value,
            style: AppTheme.getAnalyticsHeadingStyle(
              context,
              fontSize: 28,
            ).copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(stat.label, style: AppTheme.getAnalyticsCaptionStyle(context)),
          const SizedBox(height: 8),
          Text(
            stat.caption,
            style: AppTheme.getAnalyticsSecondaryStyle(context),
          ),
        ],
      ),
    );
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.getBorderColor(context)),
        boxShadow: AppTheme.getCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTheme.getAnalyticsHeadingStyle(context, fontSize: 20),
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

  const _PriorityBar({
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = value.clamp(0.0, 1.0);
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
                  style: AppTheme.getAnalyticsHeadingStyle(
                    context,
                    fontSize: 15,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                valueLabel,
                style: AppTheme.getAnalyticsSecondaryStyle(context),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: normalized,
              backgroundColor: AppTheme.getBorderColor(context),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

class _InsightChip extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  final IconData icon;

  const _InsightChip({
    required this.title,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTheme.getAnalyticsCaptionStyle(context)),
              const SizedBox(height: 2),
              Text(
                value,
                style: AppTheme.getAnalyticsHeadingStyle(context, fontSize: 18)
                    .copyWith(
                      color: AppTheme.getAnalyticsAccentTextColor(
                        context,
                        color,
                      ),
                    ),
              ),
            ],
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
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: coverage.clamp(0.0, 1.0),
              backgroundColor: AppTheme.getBorderColor(context),
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppTheme.primaryBlue,
              ),
            ),
          ),
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
          color: AppTheme.getSecondaryBg(context),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.getBorderColor(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              vehicleName == 'N/A' ? 'Unknown' : vehicleName,
              style: AppTheme.getAnalyticsHeadingStyle(context, fontSize: 16),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _watchlistCell(context, 'Temperature', temperatureValue),
          ),
          const SizedBox(width: 12),
          Expanded(child: _watchlistCell(context, 'Humidity', humidityValue)),
          const SizedBox(width: 12),
          badge,
        ],
      ),
    );
  }

  Widget _watchlistCell(BuildContext context, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTheme.getAnalyticsCaptionStyle(context)),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.getAnalyticsHeadingStyle(
            context,
            fontSize: 14,
          ).copyWith(fontWeight: FontWeight.w700),
        ),
      ],
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
    final diagnostics = _mapOf(asset['diagnostics']);
    final fuel = _mapOf(diagnostics['fuelLevel']);
    final engineHours = _mapOf(diagnostics['engineHours']);
    final odometer = _mapOf(diagnostics['rawOdometer']);
    final alerts = _mapOf(asset['alerts']);
    final alertCount = _toInt(asset['alertCount']);
    final fuelFallbackRatio = _toDouble(asset['fuelLevelRatio']);
    final engineHoursFallback = _toDouble(asset['engineHours']);
    final odometerFallback = _toDouble(asset['odometerKm']);
    final vehicleName = formatValue(asset['vehicle']);
    final status = formatValue(asset['status']);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.getSecondaryBg(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: alertCount > 0
              ? AppTheme.warningOrange.withValues(alpha: 0.22)
              : AppTheme.getBorderColor(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
                    ),
                    const SizedBox(height: 4),
                    Text(
                      status == 'N/A' ? 'available' : status,
                      style: AppTheme.getAnalyticsSecondaryStyle(context),
                    ),
                  ],
                ),
              ),
              if (alerts['offline'] == true)
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
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _TagMetric(
                label: 'Fuel',
                value: _diagnosticDisplay(
                  fuel,
                  fallback: fuelFallbackRatio > 0
                      ? '${(fuelFallbackRatio * 100).toStringAsFixed(0)}%'
                      : 'N/A',
                ),
              ),
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
              _TagMetric(label: 'Alerts', value: '$alertCount'),
            ],
          ),
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

  const _TagMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.getCardBg(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.getBorderColor(context)),
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
  });

  final String title;
  final String value;
  final String caption;
}

class _AnalyticsSectionHeader extends StatelessWidget {
  const _AnalyticsSectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 4,
          height: 45,
          decoration: BoxDecoration(
            color: AppTheme.pioneerRed,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
          ),
        ),
      ],
    );
  }
}

class _SampleDataBanner extends StatelessWidget {
  const _SampleDataBanner();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: AppTheme.warningOrange),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.warningOrange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.science_outlined,
              color: AppTheme.warningOrange,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Sample data \u2014 replace when real fleet data is available.',
                style: AppTheme.getAnalyticsBodyStyle(context).copyWith(
                  color: AppTheme.warningOrange,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(
            distance,
            (distance + 6).clamp(0, metric.length).toDouble(),
          ),
          paint,
        );
        distance += 10;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
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
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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

class _AnalyticsInsightBlock extends StatelessWidget {
  const _AnalyticsInsightBlock({
    required this.title,
    required this.rows,
    required this.isSample,
  });

  final String title;
  final List<_InsightLine> rows;
  final bool isSample;

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
          : Column(
              children: rows
                  .map(
                    (row) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                                const SizedBox(height: 2),
                                Text(
                                  row.caption,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.getAnalyticsSecondaryStyle(
                                    context,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            row.value,
                            style: AppTheme.getAnalyticsBodyStyle(context)
                                .copyWith(
                                  fontWeight: FontWeight.w900,
                                  color: AppTheme.getAnalyticsAccentTextColor(
                                    context,
                                    AppTheme.primaryBlue,
                                  ),
                                ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
    );
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
}

class _AnalyticsStat {
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color color;

  const _AnalyticsStat({
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
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
    'fuelLevelRatio': 0.67,
    'engineHours': 1940,
    'odometerKm': 61340,
    'alertCount': 0,
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
    'rollingAverageLabel': 'PHP 5,420',
    'costLabel': 'PHP 5,180',
  },
  {
    'label': 'Week 2',
    'rollingAverageLabel': 'PHP 5,680',
    'costLabel': 'PHP 5,940',
  },
  {
    'label': 'Week 3',
    'rollingAverageLabel': 'PHP 5,590',
    'costLabel': 'PHP 5,410',
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
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
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
